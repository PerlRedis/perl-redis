use strict;
use warnings;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::SharedFork;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv) = redis();
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

my $o = Redis->new(server => $srv,
                   name => 'my_name_is_glorious',
                   ssl => $use_ssl,
                   SSL_verify_mode => 0);
is $o->info->{connected_clients}, 1;
my $localport = $o->{sock}->sockport;

note "fork safe"; {
    if (my $pid = fork) {
        $o->incr("test-fork");
        is $o->{sock}->sockport, $localport, "same port on parent";
        waitpid($pid, 0);
    }
    else {
        $o->incr("test-fork");
        isnt $o->{sock}->sockport, $localport, "different port on child";
        is $o->info->{connected_clients}, 2, "2 clients connected";
        exit 0;
    }

    is $o->get('test-fork'), 2;
};

done_testing;
