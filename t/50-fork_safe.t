use strict;
use warnings;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }
my $o = Redis->new(server => $srv, name => 'my_name_is_glorious');

note "fork safe"; {
    if (my $pid = fork) {
        $o->incr("test-fork");
        waitpid($pid, 0);
    }
    else {
        $o->incr("test-fork");
        exit 0;
    }

    is $o->get('test-fork'), 2;
};

done_testing;
