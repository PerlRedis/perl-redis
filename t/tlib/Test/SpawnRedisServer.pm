package    # Hide from PAUSE
  Test::SpawnRedisServer;

use strict;
use warnings;
use Redis;
use File::Temp;
use IPC::Cmd qw(can_run);
use POSIX ":sys_wait_h";
use base qw( Exporter );

our @EXPORT    = qw( redis );
our @EXPORT_OK = qw( redis reap );

## FIXME: for the love of $Deity... move to Test::TCP, will you??
my $port = 11011 + ($$ % 127);

sub redis {
  my %params = (
    timeout => 120,
    @_,
  );

  my ($fh, $fn) = File::Temp::tempfile();

  $port++;
  my $addr = "127.0.0.1:$port";

  unlink("redis-server-$addr.log");
  unlink('dump.rdb');

  $fh->print("
    timeout $params{timeout}
    appendonly no
    daemonize no
    port $port
    bind 127.0.0.1
    loglevel debug
    logfile redis-server-$addr.log
  ");
  $fh->flush;

  Test::More::diag("Spawn Redis at $addr, cfg $fn") if $ENV{REDIS_DEBUG};

  my $redis_server_path = $ENV{REDIS_SERVER_PATH} || 'redis-server';
  if (!can_run($redis_server_path)) {
    Test::More::plan skip_all => "Could not find binary redis-server";
    return;
  }

  my ($ver, $c);
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

  return ($c, $addr, $ver, split(/[.]/, $ver));
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
      unlink('dump.rdb');
      $alive = 0;
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

sub reap {
  my ($pid, $limit) = @_;
  $pid   = -1 unless $pid;
  $limit = 3  unless $limit;

  my $try = 0;
  while ($try++ < $limit) {
    my $ok = waitpid($pid, WNOHANG);
    $try = 0, last if $ok > 0;
    sleep(1);
  }

  return $try;
}

1;
