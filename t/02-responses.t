#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Test::Deep;
use IO::String;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }


ok(my $r = Redis->new(server => $srv), 'connected to our test redis-server');

sub r {
  $r->{sock} = IO::String->new(join('', map {"$_\r\n"} @_));
}

## -ERR responses
r('-you must die!!');
is_deeply([$r->__read_response('cmd')], [undef, 'you must die!!'], 'Error response detected');


## +TEXT responses
my $m;
r('+all your text are belong to us');
is_deeply([$r->__read_response('cmd')], ['all your text are belong to us', undef], 'Text response ok');


## :NUMBER responses
r(':234');
is_deeply([$r->__read_response('cmd')], [234, undef], 'Integer response ok');


## $SIZE PAYLOAD responses
r('$19', "Redis\r\nis\r\ngreat!\r\n");
is_deeply([$r->__read_response('cmd')], ["Redis\r\nis\r\ngreat!\r\n", undef], 'Size+payload response ok');

r('$0', "");
is_deeply([$r->__read_response('cmd')], ['', undef], 'Zero-size+payload response ok');

r('$-1');
is_deeply([$r->__read_response('cmd')], [undef, undef], 'Negative-size+payload response ok');


## Multi-bulk responses
my @m;
r('*4', '$5', 'Redis', ':42', '$-1', '+Cool stuff');
cmp_deeply([$r->__read_response('cmd')], [['Redis', 42, undef, 'Cool stuff'], undef], 'Simple multi-bulk response ok');


## Nested Multi-bulk responses
r('*5', '$5', 'Redis', ':42', '*4', ':1', ':2', '$4', 'hope', '*2', ':4', ':5', '$-1', '+Cool stuff');
cmp_deeply(
  [$r->__read_response('cmd')],
  [['Redis', 42, [1, 2, 'hope', [4, 5]], undef, 'Cool stuff'], undef],
  'Nested multi-bulk response ok'
);


## Nil multi-bulk responses
r('*-1');
is_deeply([$r->__read_response('cmd')], [undef, undef], 'Read a NIL multi-bulk response');


## Multi-bulk responses with nested error
r('*3', '$5', 'Redis', '-you must die!!', ':42');
like(
  exception { $r->__read_response('cmd') },
  qr/\[cmd\] you must die!!/,
  'Nested errors must usually throw exceptions'
);

r('*3', '$5', 'Redis', '-you must die!!', ':42');
is_deeply(
  [$r->__read_response('cmd', 1)],
  [[['Redis', undef], [undef, 'you must die!!'], [42, undef]], undef,],
  'Nested errors must be collected in collect-errors mode'
);


done_testing();
