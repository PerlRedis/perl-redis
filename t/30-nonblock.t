#!perl

use strict;
use warnings;
use Test::More;
use Redis;

my $r = Redis->new;

## Try to read from server (nothing sent, so nothing to read)
## But kill if we block
local $SIG{ALRM} = sub { kill 9, $$ };
alarm(2);
ok(!$r->__can_read_sock, "Nothing to read, didn't block");
alarm(0);

done_testing();
