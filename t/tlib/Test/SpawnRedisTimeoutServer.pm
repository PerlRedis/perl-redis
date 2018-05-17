package    # Hide from PAUSE
  Test::SpawnRedisTimeoutServer;

use strict;
use warnings;
use Test::TCP;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

sub create_server_with_timeout {
    my $timeout = shift;

    Test::TCP->new(
        code => sub {
            my $port = shift;

            my %args = (
                Listen    => 5,
                Timeout   => 1,
                Reuse     => 1,
                Blocking  => 1,
                LocalPort => $port,
            );

            my $socket_class = 'IO::Socket::INET';

            if ( SSL_AVAILABLE ) {
                $socket_class = 'IO::Socket::SSL';

                $args{SSL_cert_file} = 't/stunnel/cert.pem';
                $args{SSL_key_file}  = 't/stunnel/key.pem';
            }

            my $socket = $socket_class->new(%args)
              or die "failed to connect to RedisTimeoutServer: $!";

            my $buffer;
            while (1) {
                my $client = $socket->accept();

                next unless defined $client;

                if (defined (my $got = <$client>)) {
                    sleep $timeout;
                    $client->print("+42\r\n");
                }
            }
        },
    );
}
1;
