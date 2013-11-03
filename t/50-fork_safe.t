use strict;
use warnings;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::SharedFork;

my ($c, $srv) = redis();
END { $c->() if $c }
my $o = Redis->new(server => $srv, name => 'my_name_is_glorious');
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
