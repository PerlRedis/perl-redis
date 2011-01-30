#!perl

use warnings;
use strict;
use Test::More;
use Redis::List;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($guard, $srv) = redis();

## Setup
my @my_list;
ok(my $redis = tie(@my_list, 'Redis::List', 'my_list', server => $srv),
  'tied to our test redis-server');
ok($redis->ping, 'pinged fine');
isa_ok($redis, 'Redis::List');


## Direct access
subtest 'direct access' => sub {
  @my_list = ();
  is_deeply(\@my_list, [], 'empty list ok');

  @my_list = ('foo', 'bar', 'baz');
  is_deeply(\@my_list, ['foo', 'bar', 'baz'], 'Set multiple values ok');

  $my_list[1] = 'BAR';
  is_deeply(\@my_list, ['foo', 'BAR', 'baz'], 'Set single value ok');

  is($my_list[2]++, 'baz', 'get single value ok');
  is(++$my_list[2], 'bbb', '... even with post/pre-increments');
};


## List functions
subtest 'list functions' => sub {
  my $v;

  ok($v = shift(@my_list), 'shift ok');
  is($v, 'foo', '... expected value');
  is_deeply(\@my_list, ['BAR', 'bbb'], '... resulting list as expected');

  ok(push(@my_list, $v), 'push ok');
  is_deeply(
    \@my_list,
    ['BAR', 'bbb', 'foo'],
    '... resulting list as expected'
  );

  ok($v = pop(@my_list), 'pop ok');
  is($v, 'foo', '... expected value');
  is_deeply(\@my_list, ['BAR', 'bbb'], '... resulting list as expected');

  ok(unshift(@my_list, $v), 'unshift ok');
  is_deeply(
    \@my_list,
    ['foo', 'BAR', 'bbb'],
    '... resulting list as expected'
  );

  ok(my @s = splice(@my_list, 1, 2), 'splice ok');
  is_deeply([@s], ['BAR', 'bbb'], '... resulting list as expected');
  is_deeply(
    \@my_list,
    ['foo', 'BAR', 'bbb'],'... original list as expected'
  );
};


## Cleanup
@my_list = ();
is_deeply(\@my_list, [], 'empty list ok');

done_testing();
