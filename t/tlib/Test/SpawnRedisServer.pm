package    # Hide from PAUSE
  Test::SpawnRedisServer;

use strict;
use warnings;
use Redis;
use File::Temp;
use IPC::Cmd qw(can_run);
use POSIX ":sys_wait_h";
use base qw( Exporter );

our @EXPORT = qw( redis );

sub redis {
  my %params = (
    timeout => 120,
    @_,
  );
  my ($fh, $fn) = File::Temp::tempfile();
  my $port = 11011 + ($$ % 127);

  unlink('redis-server.log');
  unlink('dump.rdb');

  $fh->print("
    timeout $params{timeout}
    appendonly no
    daemonize no
    port $port
    bind 127.0.0.1
    loglevel debug
    logfile redis-server.log
  ");
  $fh->flush;

  my $addr = "127.0.0.1:$port";
  Test::More::diag("Spawn Redis at $addr, cfg $fn") if $ENV{REDIS_DEBUG};

  my $redis_server_path = $ENV{REDIS_SERVER_PATH} || 'redis-server';
  if (! can_run($redis_server_path)) {
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
    my $alive   = 1;

    my $c = sub {
      return unless $alive;

      Test::More::diag("Killing server at $pid") if $ENV{REDIS_DEBUG};
      kill(15, $pid);

      my $failed = reap($pid);
      Test::More::diag("Failed to kill server at $pid")
        if $ENV{REDIS_DEBUG} and $failed;
      unlink('redis-server.log');
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
  my ($pid) = @_;
  $pid = -1 unless $pid;

  my $try = 0;
  while ($try++ < 3) {
    my $ok = waitpid($pid, WNOHANG);
    $try = 0, last if $ok > 0;
    sleep(1);
  }

  return $try;
}

1;
