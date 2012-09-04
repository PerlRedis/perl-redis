package    # Hide from PAUSE
  Test::SpawnRedisServer;

use strict;
use warnings;
use File::Temp;
use IPC::Cmd qw(can_run);
use POSIX ":sys_wait_h";
use base qw( Exporter );

our @EXPORT = qw( redis );

sub redis {
  my ($fh, $fn) = File::Temp::tempfile();
  my $port = 11011 + ($$ % 127);

  unlink('redis-server.log');
  unlink('dump.rdb');

  $fh->print("
    timeout 1
    appendonly no
    daemonize no
    port $port
    bind 127.0.0.1
    loglevel debug
    logfile redis-server.log
  ");
  $fh->flush;

  Test::More::diag("Redis port $port, cfg $fn") if $ENV{REDIS_DEBUG};

  my $redis_server_path = $ENV{REDIS_SERVER_PATH} || 'redis-server';
  if (! can_run($redis_server_path)) {
    Test::More::plan skip_all => "Could not find binary redis-server";
    return;
  }

  my $c;
  eval { $c = spawn_server($redis_server_path, $fn) };
  if (my $e = $@) {
    Test::More::plan skip_all => "Could not start redis-server: $@";
    return;
  }

  return ($c, "127.0.0.1:$port");
}

sub spawn_server {
  my $pid = fork();
  if ($pid) {    ## Parent
    require Test::More;
    Test::More::diag("Starting server with pid $pid") if $ENV{REDIS_DEBUG};

    ## FIXME: we should PING it until he is ready
    sleep(1);
    my $alive = 1;

    return sub {
      return unless $alive;

      Test::More::diag("Killing server at $pid") if $ENV{REDIS_DEBUG};
      kill(15, $pid);

      my $try = 0;
      while ($try++ < 10) {
        my $ok = waitpid($pid, WNOHANG);
        $try = -1, last if $ok > 0;
        sleep(1);
      }
      Test::More::diag("Failed to kill server at $pid")
        if $ENV{REDIS_DEBUG} && $try > 0;
      unlink('redis-server.log');
      unlink('dump.rdb');
      $alive = 0;
    };
  }
  elsif (defined $pid) {    ## Child
    exec(@_);
    die "Failed exec of '@_': $!, ";
  }

  die "Could not fork(): $!";
}


1;
