#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Redis;
use Redis::Sentinel;
use lib 't/tlib';
use Test::SpawnRedisServer;

my @ret = redis();
my $redis_port = pop @ret;
my ($c, $redis_addr) = @ret;
END { diag 'shutting down redis'; $c->() if $c }

diag "redis address : $redis_addr\n";

my @ret2 = sentinel( redis_port => $redis_port );
my $sentinel_port = pop @ret2;
my ($c2, $sentinel_addr) = @ret2;
END { diag 'shutting down sentinel'; $c2->() if $c2 }

my @ret3 = sentinel( redis_port => $redis_port );
my $sentinel2_port = pop @ret3;
my ($c3, $sentinel2_addr) = @ret3;
END { diag 'shutting down sentinel2'; $c3->() if $c3 }

diag "sentinel address: $sentinel_addr\n";
diag "sentinel2 address: $sentinel2_addr\n";

diag("wait 3 sec for the sentinels and the master to gossip");
sleep 3;

{
    # check basic sentinel command
    my $sentinel = Redis::Sentinel->new(server => $sentinel_addr);
    my $got = ($sentinel->get_masters())[0];

    cmp_deeply($got, superhashof({ name => 'mymaster',
                      ip => '127.0.0.1',
                      port => $redis_port,
                      flags => 'master',
                      'role-reported' => 'master',
                      'config-epoch' => 0,
                      'num-slaves' => 0,
                      'num-other-sentinels' => 1,
                      quorum => 2,
                    }),
              "sentinel has proper config of its master"
             );
}

{
    my $sentinel = Redis::Sentinel->new(server => $sentinel_addr);
    my $address = $sentinel->get_service_address('mymaster');
    is $address, "127.0.0.1:$redis_port", "found service mymaster";
}

{
    my $sentinel = Redis::Sentinel->new(server => $sentinel_addr);
    my $address = $sentinel->get_service_address('mywrongmaster');
    is $address, undef, "didn't found service mywrongmaster";
}

{
   # connect to the master via the sentinel
   my $redis = Redis->new(sentinels => [ $sentinel_addr ], service => 'mymaster');
   is_deeply({ map { $_ => 1} @{$redis->{sentinels} || []} },
             { $sentinel_addr => 1, $sentinel2_addr => 1},
             "Redis client has connected and updated its sentinels");

}

done_testing();
