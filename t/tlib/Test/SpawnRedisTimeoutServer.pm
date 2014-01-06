package    # Hide from PAUSE
  Test::SpawnRedisTimeoutServer;

use strict;
use warnings;
use Test::TCP;

sub create_server_with_timeout {
    my $timeout = shift;

    Test::TCP->new(
        code => sub {
            my $port   = shift;
            my $socket = IO::Socket::INET->new(
                Listen    => 5,
                Timeout   => 1,
                Reuse     => 1,
                Blocking  => 1,
                LocalPort => $port
            ) or die "failed to connect to RedisTimeoutServer: $!";

            my $buffer;
            while (1) {
                my $client = $socket->accept();
                if (defined (my $got = <$client>)) {
                    sleep $timeout;
                    $client->print("+42\r\n");
                }
            }
        },
    );
}
1;
