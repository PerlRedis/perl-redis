#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my @ret = redis();
my $redis_port = pop @ret;
my ($c, $redis_addr) = @ret;
END { $c->() if $c }

diag "redis address : $redis_addr\n";

my @ret2 = sentinel( redis_port => $redis_port );
my $sentinel_port = pop @ret2;
my ($c2, $sentinel_addr) = @ret2;
END { $c2->() if $c2 }

diag "sentinel address: $sentinel_addr\n";

{
    # check basic sentinel command
    my $redis = Redis->new(server => $sentinel_addr);
    my $got = { @{$redis->sentinel('masters')->[0]} };

    delete @{$got}{qw(last-ok-ping-reply last-ping-reply runid role-reported-time info-refresh)};

    is_deeply($got, { name => 'mymaster',
                      ip => '127.0.0.1',
                      port => $redis_port,
                      flags => 'master',
                      'pending-commands' => 0,
                      'role-reported' => 'master',
                      'config-epoch' => 0,
                      'num-slaves' => 0,
                      'num-other-sentinels' => 0,
                      quorum => 2,
                    }
             );
}

#{
    # connect to the master via the sentinel
#    my $redis = Redis->new(sentinels => [ $sentinel_addr ], service => 'mymaster');

#    print STDERR $redis; use Data::Dumper;

# }

#sleep;

## All done
done_testing();
