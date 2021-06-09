package    # Hide from PAUSE
  Test::SpawnRedisServer;

use strict;
use warnings;
use Redis;
use File::Temp;
use IPC::Cmd qw(can_run);
use POSIX ":sys_wait_h";
use base qw( Exporter );

use Net::EmptyPort qw(empty_port);

use constant SSL_WAIT      => 2; # Wait a bit till the mock secure tunnel is up
use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

our @EXPORT    = qw( redis sentinel );
our @EXPORT_OK = qw( redis reap );

sub redis {
  my %params = (
    timeout => 120,
    @_,
  );

  my $use_ssl = $ENV{USE_SSL} ? SSL_AVAILABLE : 0;

  # Sentinel mode does not support SSL/TLS yet so we have this
  # option to explicitly turn off SSL/TLS in testing.
  $use_ssl = 0 if $params{no_ssl};

  my $port = empty_port();

  my $local_port = $port;

  my $stunnel_port = empty_port();

  if ( ! $use_ssl ) {
    # Use this specific port in non-TLS mode
    $params{port}
      and $local_port = $params{port};
  } else {
    # Reuse the same port if it is specified
    $params{port}
      and $stunnel_port = $params{port};
  }

  my $addr = "127.0.0.1:$local_port";

  unlink("redis-server-$addr.log");
  unlink('dump.rdb');

  # Spawn the tunnel first so that we know if we can test SSL/TLS setup
  my $stunnel_addr = "127.0.0.1:$stunnel_port";

  my ($ver, $c, $t);

  if ( $use_ssl ) {
    Test::More::diag("Spawn stunnel $stunnel_addr:$addr") if $ENV{REDIS_DEBUG};

    my ($stunnel_fh, $stunnel_fn) = File::Temp::tempfile();

    $stunnel_fh->print("pid=
debug = 0
foreground = yes

[redis]
accept = $stunnel_port
connect = $addr
cert = t/stunnel/cert.pem
key = t/stunnel/key.pem
");
    $stunnel_fh->flush;

    my $stunnel_path = $ENV{STUNNEL_PATH} || 'stunnel';
    if (!can_run($stunnel_path)) {
      Test::More::diag("Could not find binary stunnel, revert to plain text Redis server");

      $addr = $stunnel_addr;
      $local_port = $stunnel_port;

      $use_ssl = 0;
    }
    else {
      eval { $t = spawn_tunnel($stunnel_path, $stunnel_fn) };

      if (my $e = $@) {
        reap();
        Test::More::diag("Could not start stunnel, revert to plain text Redis server: $@");
        $use_ssl = 0
      }
    }

    sleep(SSL_WAIT) if $use_ssl;
  }

  my ($fh, $fn) = File::Temp::tempfile();

  my (undef, $sock_temp_file) = File::Temp::tempfile();

  $fh->print("
    timeout $params{timeout}
    appendonly no
    daemonize no
    port $local_port
    bind 127.0.0.1
    unixsocket $sock_temp_file
    unixsocketperm 700
    loglevel debug
    logfile FOOredis-server-$addr.log
  ");
  $fh->flush;

  Test::More::diag("Spawn Redis at $addr, cfg $fn") if $ENV{REDIS_DEBUG};

  my $redis_server_path = $ENV{REDIS_SERVER_PATH} || 'redis-server';
  if (!can_run($redis_server_path)) {
    Test::More::plan skip_all => "Could not find binary redis-server";
    return;
  }

  eval { ($ver, $c) = spawn_server($redis_server_path, $fn, $addr) };
  if (my $e = $@) {
    reap();
    Test::More::plan skip_all => "Could not start redis-server: $@";
    return;
  }

  if (my $rvs = $params{requires_version}) {
    if (!defined $ver) {
      $c->();
      Test::More::plan skip_all => "This tests require at least redis-server $rvs, could not determine server version";
      return;
    }

    my ($v1, $v2, $v3) = split(/[.]/, $ver);
    my ($r1, $r2, $r3) = split(/[.]/, $rvs);
    if ($v1 < $r1 or $v1 == $r1 and $v2 < $r2 or $v1 == $r1 and $v2 == $r2 and $v3 < $r3) {
      $c->();
      Test::More::plan skip_all => "This tests require at least redis-server $rvs, server found is $ver";
      return;
    }
  }

  if ( $use_ssl ) {
    # Connect to Redis through stunnel
    return ($c, $t, $stunnel_addr, $ver, split(/[.]/, $ver), $stunnel_port, $sock_temp_file);
  } else {
    # Connect to Redis directly
    return ($c, $addr, $ver, split(/[.]/, $ver), $local_port, $sock_temp_file);
  }
}

sub sentinel {
  my %params = (
    timeout => 120,
    @_,
  );

  my ($fh, $fn) = File::Temp::tempfile();

  my $port = empty_port();

  my $local_port = $port;
  $params{port}
    and $local_port = $params{port};

  my $redis_port = $params{redis_port}
    or die "need a redis port";

  my $addr = "127.0.0.1:$local_port";

  unlink("redis-sentinel-$addr.log");

  $fh->print("
    port $local_port
    
    sentinel monitor mymaster 127.0.0.1 $redis_port 2
    sentinel down-after-milliseconds mymaster 2000
    sentinel failover-timeout mymaster 4000

    logfile sentinel-$addr.log

  ");
  $fh->flush;

  my $redis_server_path = $ENV{REDIS_SERVER_PATH} || 'redis-server';
  if (!can_run($redis_server_path)) {
    Test::More::plan skip_all => "Could not find binary redis-server";
    return;
  }

  my ($ver, $c);
  eval { ($ver, $c) = spawn_server($redis_server_path, $fn, '--sentinel', $addr) };
  if (my $e = $@) {
    reap();
    Test::More::plan skip_all => "Could not start redis-sentinel: $@";
    return;
  }

  if (my $rvs = $params{requires_version}) {
    if (!defined $ver) {
      $c->();
      Test::More::plan skip_all => "This tests require at least redis-server $rvs, could not determine server version";
      return;
    }

    my ($v1, $v2, $v3) = split(/[.]/, $ver);
    my ($r1, $r2, $r3) = split(/[.]/, $rvs);
    if ($v1 < $r1 or $v1 == $r1 and $v2 < $r2 or $v1 == $r1 and $v2 == $r2 and $v3 < $r3) {
      $c->();
      Test::More::plan skip_all => "This tests require at least redis-server $rvs, server found is $ver";
      return;
    }
  }

  return ($c, $addr, $ver, split(/[.]/, $ver), $local_port);
}

sub spawn_server {
  my $addr = pop;
  my $pid  = fork();
  if ($pid) {    ## Parent
    require Test::More;
    Test::More::diag("Starting server with pid $pid") if $ENV{REDIS_DEBUG};

    my $redis   = Redis->new(server => $addr, reconnect => 5, every => 200);
    my $version = $redis->info->{redis_version};
    my $alive   = $$;

    my $c = sub {
      return unless $alive;
      return unless $$ == $alive;    ## only our creator can kill us

      Test::More::diag("Killing server at $pid") if $ENV{REDIS_DEBUG};
      kill(15, $pid);

      my $failed = reap($pid);
      Test::More::diag("Failed to kill server at $pid")
        if $ENV{REDIS_DEBUG} and $failed;
      unlink("redis-server-$addr.log");
      unlink("redis-sentinel-$addr.log");
      unlink('dump.rdb');
      $alive = 0;

      return !$failed;
    };

    return $version => $c;
  }
  elsif (defined $pid) {    ## Child
    exec(@_);
    warn "## In child Failed exec of '@_': $!, ";
    exit(1);
  }

  die "Could not fork(): $!";
}

sub spawn_tunnel {
  my ($stunnel, $stunnel_cfg) = @_;

  my $cmd = "$stunnel $stunnel_cfg";

  my $pid = fork();
  if ($pid) {
    require Test::More;
    Test::More::diag("Starting stunnel $cmd pid $pid") if $ENV{REDIS_DEBUG};

    my $alive = $$;

    my $c = sub {
      return unless $alive;
      return unless $$ == $alive;    ## only our creator can kill us

      Test::More::diag("Killing stunnel at $pid") if $ENV{REDIS_DEBUG};
      kill(15, $pid);

      my $failed = reap($pid);
      Test::More::diag("Failed to kill stunnel at $pid")
        if $ENV{REDIS_DEBUG} and $failed;
      $alive = 0;

      return !$failed;
    };

    return $c;
  }
  elsif (defined $pid) {
    exec($cmd);
    warn "## In child Failed exec of '$cmd': $!, ";
    exit(1);
  }

  die "Could not fork() stunnel: $!";
}

sub reap {
  my ($pid, $limit) = @_;
  $pid   = -1 unless $pid;
  $limit = 3  unless $limit;

  my $try = 0;
  local $?;
  while ($try++ < $limit) {
    my $ok = waitpid($pid, WNOHANG);
    $try = 0, last if $ok > 0;
    sleep(1);
  }

  return $try;
}

1;
