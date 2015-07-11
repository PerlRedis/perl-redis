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

my @ret_m = redis();
my $redis_m_port = pop @ret_m;
my ($c_m, $redis_m_addr) = @ret_m;
END { diag 'shutting down redis'; $c_m->() if $c_m }

diag "redis master address : $redis_m_addr\n";

my @ret_s = redis();
my $redis_s_port = pop @ret_s;
my ($c_s, $redis_s_addr) = @ret_s;
END { diag 'shutting down redis'; $c_s->() if $c_s }

eval { Redis->new(server => $redis_s_addr)->slaveof('127.0.0.1', $redis_m_port); 1 } or do {
  plan skip_all => '** FAILED to set slave server as a SLAVEOF master, aborting tests **';
};

diag "redis slave address : $redis_s_addr\n";

diag('Waiting 1 second to make sure the master/slave setup is in place before starting Sentinels');
sleep 1;

my @ret2 = sentinel( redis_port => $redis_m_port );
my $sentinel_port = pop @ret2;
my ($c2, $sentinel_addr) = @ret2;
END { diag 'shutting down sentinel'; $c2->() if $c2 }

my @ret3 = sentinel( redis_port => $redis_m_port );
my $sentinel2_port = pop @ret3;
my ($c3, $sentinel2_addr) = @ret3;
END { diag 'shutting down sentinel2'; $c3->() if $c3 }

diag "sentinel address: $sentinel_addr\n";
diag "sentinel2 address: $sentinel2_addr\n";

diag("wait 3 secs for the sentinels and the master to gossip");
sleep 3;

{
    # check basic sentinel command
    my $sentinel = Redis::Sentinel->new(server => $sentinel_addr);
    my $got = ($sentinel->get_masters())[0];

    cmp_deeply($got, superhashof({ name => 'mymaster',
                      ip => '127.0.0.1',
                      port => $redis_m_port,
                      flags => 'master',
                      'role-reported' => 'master',
                      'config-epoch' => 0,
                      'num-slaves' => 1,
                      'num-other-sentinels' => 1,
                      quorum => 2,
                    }),
              "sentinel has proper config of its master"
             );

    $got = $sentinel->get_slaves('mymaster');
    cmp_deeply(
      $got,
      [ superhashof(
          { 'port'          => $redis_s_port,
            'flags'         => "slave",
            'master-port'   => $redis_m_port,
            'role-reported' => "slave",
            'name'          => "127.0.0.1:$redis_s_port",
          }
        )
      ],
      "sentinel has proper config of its slaves"
    );
}

{
    my $sentinel = Redis::Sentinel->new(server => $sentinel_addr);
    my $address = $sentinel->get_service_address('mymaster');
    is $address, "127.0.0.1:$redis_m_port", "found service mymaster";
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

{
   # connect to the slave via the sentinel
   my $redis = Redis->new(sentinels => [ $sentinel_addr ], service => 'mymaster', role => 'slave');
   is($redis->__get_server_role(), 'slave', 'Redis client connect to slave server via Sentinel');
}

done_testing();
