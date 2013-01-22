package    # Hide from PAUSE
  Test::SpawnFakeRedis;

use strict;
use warnings;
use Test::More ();
use IPC::Cmd qw(can_run);
use POSIX ":sys_wait_h";
use base qw( Exporter );
use IO::Socket;

our @EXPORT = qw( redis );

sub redis {
  my $port    = 11011 + ($$ % 127);
  my $address = "127.0.0.1:$port";
  Test::More::diag("Spawn Fake Redis at $address") if $ENV{REDIS_DEBUG};

  my $cleanup;
  eval { $cleanup = spawn_server($address) };
  if (my $error = $@) {
    reap();
    Test::More::plan(skip_all => "Could not start fake redis-server: $error");
    return;
  }

  return ($cleanup, $address);
}

sub spawn_server {
  my $address = pop;
  my $pid  = fork();
  if ($pid) {    ## Parent
    sleep 1;
    Test::More::diag("Starting fake server with pid $pid") if $ENV{REDIS_DEBUG};

    my $alive  = 1;

    my $cleanup = sub {
      return unless $alive;

      Test::More::diag("Killing fake server at $pid") if $ENV{REDIS_DEBUG};
      kill(15, $pid);

      my $failed = reap($pid);
      Test::More::diag("Failed to kill server at $pid")
        if $ENV{REDIS_DEBUG} and $failed;
      $alive = 0;
    };

    return $cleanup;
  }
  elsif (defined $pid) {    ## Child
    my $socket = IO::Socket::INET->new(
      LocalHost => $address,
      Proto     => 'tcp',
      Listen    => 1,
      Reuse     => 1,
    ) or die "Could not create socket: $!";

    my @last_command;
    while ( my $new_socket = $socket->accept ) {
      while ( <$new_socket> ) {
        if ( $ENV{REDIS_DEBUG} ) {
          require Data::Dumper;
          Test::More::diag(Data::Dumper->Dump([$_]=>['request']));
        }
        if ( /PING/ ) {
          print $new_socket "+PONG\n";
        }
        elsif ( /^\*3/ ) { # this is the set command we'll sleep on
          # block the server
          sleep 30;
          print $new_socket $_;
        }
        else {
          # cheap hack
          print $new_socket $_;
        }
      }
      close $new_socket;
    }
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
