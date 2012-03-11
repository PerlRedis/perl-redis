package Redis;

use warnings;
use strict;

use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use IO::Handle;
use Fcntl qw( O_NONBLOCK F_SETFL );
use Data::Dumper;
use Carp qw/confess/;
use Encode;
use Try::Tiny;
use Scalar::Util ();

=head1 NAME

Redis - perl binding for Redis database

=cut

our $VERSION = '1.926';

=head1 SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis->new;
    
    my $redis = Redis->new(server => 'redis.example.com:8080');
    
    ## Use UNIX domain socket
    my $redis = Redis->new(sock => '/path/to/socket');
    
    ## Enable auto-reconnect
    ## Try to reconnect every 500ms up to 60 seconds until success
    ## Die if you can't after that
    my $redis = Redis->new(reconnect => 60);
    
    ## Try each 100ms upto 2 seconds (every is in milisecs)
    my $redis = Redis->new(reconnect => 2, every => 100);
    
    ## Disable the automatic utf8 encoding => much more performance
    my $redis = Redis->new(encoding => undef);
    
    ## Use all the regular Redis commands, they all accept a list of
    ## arguments
    ## See http://redis.io/commands for full list
    $redis->get('key');
    $redis->set('key' => 'value');
    $redis->sort('list', 'DESC');
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC});
    
    ## Add a coderef argument to run a command in the background
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC}, sub {
      my ($reply, $error) = @_;
      die "Oops, got an error: $error\n" if defined $error;
      print "$_\n" for @$reply;
    });
    long_computation();
    $redis->wait_all_responses;
    
    ## Or run a large batch of commands in a pipeline
    $redis->hset('h', $_, $hash{$_}, sub {}) for keys %hash;
    $redis->wait_all_responses;
    
    ## Publish/Subscribe
    $redis->subscribe(
      'topic_1',
      'topic_2',
      sub {
        my ($message, $topic, $subscribed_topic) = @_
    
          ## $subscribed_topic can be different from topic if
          ## you use psubscribe() with wildcards
      }
    );
    $redis->psubscribe('nasdaq.*', sub {...});
    
    ## Blocks and waits for messages, calls subscribe() callbacks
    ##  ... forever
    $redis->wait_for_messages($timeout) while 1;
    
    ##  ... until some condition
    $redis->wait_for_messages($timeout) while $keep_going;
    
    $redis->publish('topic_1', 'message');


=head1 DESCRIPTION

Pure perl bindings for L<http://redis.io/>

This version supports protocol 2.x (multi-bulk) or later of Redis
available at L<https://github.com/antirez/redis/>.

This documentation lists commands which are exercised in test suite, but
additional commands will work correctly since protocol specifies enough
information to support almost all commands with same piece of code with
a little help of C<AUTOLOAD>.


=head1 METHODS

=head2 new

    my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

    my $r = Redis->new( server => '192.168.0.1:6379', debug => 0 );
    my $r = Redis->new( server => '192.168.0.1:6379', encoding => undef );
    my $r = Redis->new( sock => '/path/to/sock' );
    my $r = Redis->new( reconnect => 60, every => 5000 );

The C<< server >> parameter specifies the Redis server we should connect
to, via TCP. Use the 'IP:PORT' format. If no C<< server >> option is
present, we will attempt to use the C<< REDIS_SERVER >> environment
variable. If neither of those options are present, it defaults to
'127.0.0.1:6379'.

Alternatively you can use the C<< sock >> parameter to specify the path
of the UNIX domain socket where the Redis server is listening.

The C<< REDIS_SERVER >> can be used for UNIX domain sockets too. The following formats are supported:

=over 4

=item /path/to/sock

=item unix:/path/to/sock

=item 127.0.0.1:11011

=item tcp:127.0.0.1:11011

=back

The C<< encoding >> parameter speficies the encoding we will use to
decode all the data we receive and encode all the data sent to the redis
server. Due to backwards-compatibility we default to C<< utf8 >>. To
disable all this encoding/decoding, you must use C<<encoding => undef>>.
B<< This is the recommended option >>.

B<< Warning >>: this option has several problems and it is
B<deprecated>. A future version will add a safer option.

The C<< reconnect >> option enables auto-reconnection mode. If we cannot
connect to the Redis server, or if a network write fails, we enter retry
mode. We will try a new connection every C<< every >> miliseconds
(1000ms by default), up-to C<< reconnect >> seconds.

Be aware that read errors will always thrown an exception, and will not
trigger a retry until the new command is sent.

If we cannot re-establish a connection after C<< reconnect >> seconds,
an exception will be thrown.

The C<< debug >> parameter enables debug information to STDERR,
including all interactions with the server. You can also enable debug
with the C<REDIS_DEBUG> environment variable.

=cut

sub new {
  my $class = shift;
  my %args  = @_;
  my $self  = bless {}, $class;

  $self->{debug} = $args{debug} || $ENV{REDIS_DEBUG};

  ## default to lax utf8
  $self->{encoding} = exists $args{encoding}? $args{encoding} : 'utf8';

  ## Deal with REDIS_SERVER ENV
  if ($ENV{REDIS_SERVER} && !$args{sock} && !$args{server}) {
    if ($ENV{REDIS_SERVER} =~ m!^/!) {
      $args{sock} = $ENV{REDIS_SERVER};
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^unix:(.+)!) {
      $args{sock} = $1;
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^(tcp:)?(.+)!) {
      $args{server} = $2;
    }
  }

  if ($args{sock}) {
    $self->{server} = $args{sock};
    $self->{builder} = sub { IO::Socket::UNIX->new($_[0]->{server}) };
  }
  else {
    $self->{server} = $args{server} || '127.0.0.1:6379';
    $self->{builder} = sub {
      IO::Socket::INET->new(
        PeerAddr => $_[0]->{server},
        Proto    => 'tcp',
      );
    };
  }

  $self->{is_subscriber} = 0;
  $self->{subscribers}   = {};
  $self->{reconnect}     = $args{reconnect} || 0;
  $self->{every}         = $args{every} || 1000;

  $self->__connect;

  return $self;
}

sub is_subscriber { $_[0]{is_subscriber} }


### we don't want DESTROY to fallback into AUTOLOAD
sub DESTROY { }


### Deal with common, general case, Redis commands
our $AUTOLOAD;

sub AUTOLOAD {
  my $command = $AUTOLOAD;
  $command =~ s/.*://;

  my $method = sub { shift->__std_cmd($command, @_) };

  # Save this method for future calls
  no strict 'refs';
  *$AUTOLOAD = $method;

  goto $method;
}

sub __std_cmd {
  my $self    = shift;
  my $command = shift;

  $self->__is_valid_command($command);

  my $ret;
  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  # If this is an EXEC command, in pipelined mode, and one of the commands
  # executed in the transaction yields an error, we must collect all errors
  # from that command, rather than throwing an exception immediately.
  my $collect_errors = $cb && uc($command) eq 'EXEC';

  ## Fast path, no reconnect;
  return $self->__run_cmd($command, $collect_errors, undef, $cb, @_)
    unless $self->{reconnect};

  my @cmd_args = @_;
  $self->__with_reconnect(sub {
    $self->__run_cmd($command, $collect_errors, undef, $cb, @cmd_args);
  });
}

sub __with_reconnect {
  my ($self, $cb) = @_;

  ## Fast path, no reconnect
  return $cb->() unless $self->{reconnect};

  return &try($cb, catch {
    die $_ unless ref($_) eq 'Redis::X::Reconnect';

    $self->__connect;
    $cb->();
  });
}

sub __run_cmd {
  my ($self, $command, $collect_errors, $custom_decode, $cb, @args) = @_;

  my $ret;
  my $wrapper = $cb && $custom_decode ? sub {
    my ($reply, $error) = @_;
    $cb->(scalar $custom_decode->($reply), $error);
  } : $cb || sub {
    my ($reply, $error) = @_;
    confess "[$command] $error, " if defined $error;
    $ret = $reply;
  };

  $self->__send_command($command, @args);
  push @{ $self->{queue} }, [$command, $wrapper, $collect_errors];

  return 1 if $cb;

  $self->wait_all_responses;
  return $custom_decode ? $custom_decode->($ret, !wantarray)
       : wantarray && ref $ret eq 'ARRAY' ? @$ret : $ret;
}

sub wait_all_responses {
  my ($self) = @_;

  for my $handler (splice @{ $self->{queue} }) {
    my ($command, $cb, $collect_errors) = @$handler;
    $cb->($self->__read_response($command, $collect_errors));
  }

  return;
}


### Commands with extra logic
sub quit {
  my ($self) = @_;
  return unless $self->{sock};

  confess "[quit] only works in synchronous mode, "
      if @_ && ref $_[-1] eq 'CODE';

  $self->wait_all_responses;
  $self->__send_command('QUIT');
  close(delete $self->{sock}) || confess("Can't close socket: $!");

  return 1;
}

sub shutdown {
  my ($self) = @_;
  $self->__is_valid_command('SHUTDOWN');

  confess "[shutdown] only works in synchronous mode, "
      if @_ && ref $_[-1] eq 'CODE';

  return unless $self->{sock};

  $self->wait_all_responses;
  $self->__send_command('SHUTDOWN');
  close(delete $self->{sock}) || confess("Can't close socket: $!");

  return 1;
}

sub ping {
  my $self = shift;
  $self->__is_valid_command('PING');

  confess "[ping] only works in synchronous mode, "
      if @_ && ref $_[-1] eq 'CODE';

  return unless exists $self->{sock};

  $self->wait_all_responses;
  return scalar try {
    $self->__std_cmd('PING');
  }
  catch {
    close(delete $self->{sock});
    return;
  };
}

sub info {
  my $self = shift;
  $self->__is_valid_command('INFO');

  my $custom_decode = sub {
    my ($reply) = @_;
    return $reply if !defined $reply || ref $reply;
    return { map { split(/:/, $_, 2) } split(/\r\n/, $reply) };
  };

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  ## Fast path, no reconnect
  return $self->__run_cmd('INFO', 0, $custom_decode, $cb, @_)
    unless $self->{reconnect};

  my @cmd_args = @_;
  $self->__with_reconnect(sub {
    $self->__run_cmd('INFO', 0, $custom_decode, $cb, @cmd_args);
  });
}

sub keys {
  my $self = shift;
  $self->__is_valid_command('KEYS');

  my $custom_decode = sub {
    my ($reply, $synchronous_scalar) = @_;

    ## Support redis <= 1.2.6
    $reply = [split(/\s/, $reply)] if defined $reply && !ref $reply;

    return ref $reply && ($synchronous_scalar || wantarray) ? @$reply : $reply;
  };

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  ## Fast path, no reconnect
  return $self->__run_cmd('KEYS', 0, $custom_decode, $cb, @_)
    unless $self->{reconnect};

  my @cmd_args = @_;
  $self->__with_reconnect(sub {
    $self->__run_cmd('KEYS', 0, $custom_decode, $cb, @cmd_args);
  });
}


### PubSub
sub wait_for_messages {
  my ($self, $timeout) = @_;
  my $sock = $self->{sock};

  my $s = IO::Select->new;
  $s->add($sock);

  my $count = 0;
  while ($s->can_read($timeout)) {
    while (__try_read_sock($sock)) {
      my ($reply, $error) = $self->__read_response('WAIT_FOR_MESSAGES');
      confess "[WAIT_FOR_MESSAGES] $error, " if defined $error;
      $self->__process_pubsub_msg($reply);
      $count++;
    }
  }

  return $count;
}

sub __subscription_cmd {
  my $self    = shift;
  my $pr      = shift;
  my $unsub   = shift;
  my $command = shift;
  my $cb      = pop;

  confess("Missing required callback in call to $command(), ")
    unless ref($cb) eq 'CODE';

  $self->wait_all_responses;

  my @subs = @_;
  $self->__with_reconnect(sub {
    $self->__throw_reconnect('Not connected to any server')
      unless $self->{sock};

    @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
      if $unsub;
    return unless @subs;

    $self->__send_command($command, @subs);

    my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
    return $self->__process_subscription_changes($command, \%cbs);
  });
}

sub    subscribe { shift->__subscription_cmd('',  0,    subscribe => @_) }
sub   psubscribe { shift->__subscription_cmd('p', 0,   psubscribe => @_) }
sub  unsubscribe { shift->__subscription_cmd('',  1,  unsubscribe => @_) }
sub punsubscribe { shift->__subscription_cmd('p', 1, punsubscribe => @_) }

sub __process_unsubscribe_requests {
  my ($self, $cb, $pr, @unsubs) = @_;
  my $subs = $self->{subscribers};

  my @subs_to_unsubscribe;
  for my $sub (@unsubs) {
    my $key = "${pr}message:$sub";
    my $cbs = $subs->{$key} = [grep { $_ ne $cb } @{$subs->{$key}}];
    next if @$cbs;

    delete $subs->{$key};
    push @subs_to_unsubscribe, $sub;
  }

  return @subs_to_unsubscribe;
}

sub __process_subscription_changes {
  my ($self, $cmd, $expected) = @_;
  my $subs = $self->{subscribers};

  while (%$expected) {
    my ($m, $error) = $self->__read_response($cmd);
    confess "[$cmd] $error, " if defined $error;

    ## Deal with pending PUBLISH'ed messages
    if ($m->[0] =~ /^p?message$/) {
      $self->__process_pubsub_msg($m);
      next;
    }

    my ($key, $unsub) = $m->[0] =~ m/^(p)?(un)?subscribe$/;
    $key .= "message:$m->[1]";
    my $cb = delete $expected->{$key};

    push @{$subs->{$key}}, $cb unless $unsub;

    $self->{is_subscriber} = $m->[2];
  }
}

sub __process_pubsub_msg {
  my ($self, $m) = @_;
  my $subs = $self->{subscribers};

  my $sub   = $m->[1];
  my $cbid  = "$m->[0]:$sub";
  my $data  = pop @$m;
  my $topic = $m->[2] || $sub;

  if (!exists $subs->{$cbid}) {
    warn "Message for topic '$topic' ($cbid) without expected callback, ";
    return;
  }

  $_->($data, $topic, $sub) for @{$subs->{$cbid}};

  return 1;

}


### Mode validation
sub __is_valid_command {
  my ($self, $cmd) = @_;

  confess("Cannot use command '$cmd' while in SUBSCRIBE mode, ")
    if $self->{is_subscriber};
}


### Socket operations
sub __connect {
  my ($self) = @_;
  delete $self->{sock};

  # Suppose we have at least one command response pending, but we're about
  # to reconnect.  The new connection will never get a response to any of
  # the pending commands, so delete all those pending responses now.
  $self->{queue} = [];

  ## Fast path, no reconnect
  return $self->__build_sock() unless $self->{reconnect};

  ## Use precise timers on reconnections
  require Time::HiRes;
  my $t0 = [Time::HiRes::gettimeofday()];

  ## Reconnect...
  while (1) {
    eval { $self->__build_sock };

    last unless $@;    ## Connected!
    die if Time::HiRes::tv_interval($t0) > $self->{reconnect};    ## Timeout
    Time::HiRes::usleep($self->{every});                          ## Retry in...
  }

  return;
}

sub __build_sock {
  my ($self) = @_;

  $self->{sock} = $self->{builder}->($self)
    || confess("Could not connect to Redis server at $self->{server}: $!");

  return;
}

sub __send_command {
  my $self = shift;
  my $cmd  = uc(shift);
  my $enc  = $self->{encoding};
  my $deb  = $self->{debug};

  my $sock = $self->{sock}
    || $self->__throw_reconnect('Not connected to any server');

  warn "[SEND] $cmd ", Dumper([@_]) if $deb;

  ## Encode command using multi-bulk format
  my $n_elems = scalar(@_) + 1;
  my $buf     = "\*$n_elems\r\n";
  for my $elem ($cmd, @_) {
    my $bin = $enc ? encode($enc, $elem) : $elem;
    $buf .= defined($bin) ? '$' . length($bin) . "\r\n$bin\r\n" : "\$-1\r\n";
  }

  ## Check to see if socket was closed: reconnect on EOF
  my $status = __try_read_sock($sock);
  $self->__throw_reconnect('Not connected to any server')
    if defined $status && $status == 0;

  ## Send command, take care for partial writes
  warn "[SEND RAW] $buf" if $deb;
  while ($buf) {
    my $len = syswrite $sock, $buf, length $buf;
    $self->__throw_reconnect("Could not write to Redis server: $!")
      unless $len;
    substr $buf, 0, $len, "";
  }

  return;
}

sub __read_response {
  my ($self, $cmd, $collect_errors) = @_;

  confess("Not connected to any server") unless $self->{sock};

  local $/ = "\r\n";

  ## no debug => fast path
  return $self->__read_response_r($cmd, $collect_errors) unless $self->{debug};

  my ($result, $error) = $self->__read_response_r($cmd, $collect_errors);
  warn "[RECV] $cmd ", Dumper($result, $error) if $self->{debug};
  return $result, $error;
}

sub __read_response_r {
  my ($self, $command, $collect_errors) = @_;

  my ($type, $result) = $self->__read_line;

  if ($type eq '-') {
    return undef, $result;
  }
  elsif ($type eq '+' || $type eq ':') {
    return $result, undef;
  }
  elsif ($type eq '$') {
    return undef, undef if $result < 0;
    return $self->__read_len($result + 2), undef;
  }
  elsif ($type eq '*') {
    return undef, undef if $result < 0;

    my @list;
    while ($result--) {
      my @nested = $self->__read_response_r($command, $collect_errors);
      if ($collect_errors) {
        push @list, \@nested;
      }
      else {
        confess "[$command] $nested[1], " if defined $nested[1];
        push @list, $nested[0];
      }
    }
    return \@list, undef;
  }
  else {
    confess "unknown answer type: $type ($result), ";
  }
}

sub __read_line {
  my $self = $_[0];
  my $sock = $self->{sock};

  my $data = <$sock>;
  confess("Error while reading from Redis server: $!")
    unless defined $data;

  chomp $data;
  warn "[RECV RAW] '$data'" if $self->{debug};

  my $type = substr($data, 0, 1, '');
  return ($type, $data) unless $self->{encoding};
  return ($type, decode($self->{encoding}, $data));
}

sub __read_len {
  my ($self, $len) = @_;

  my $data = '';
  my $offset = 0;
  while ($len) {
    my $bytes = read $self->{sock}, $data, $len, $offset;
    confess("Error while reading from Redis server: $!")
      unless defined $bytes;
    confess("Redis server closed connection") unless $bytes;

    $offset += $bytes;
    $len -= $bytes;
  }

  chomp $data;
  warn "[RECV RAW] '$data'" if $self->{debug};

  return $data unless $self->{encoding};
  return decode($self->{encoding}, $data);
}


#
# The reason for this code:
#
# IO::Select and buffered reads like <$sock> and read() dont mix
# For example, if I receive two MESSAGE messages (from Redis PubSub),
# the first read for the first message will probably empty to socket
# buffer and move the data to the perl IO buffer.
#
# This means that IO::Select->can_read will return false (after all
# the socket buffer is empty) but from the application point of view
# there is still data to be read and process
#
# Hence this code. We try to do a non-blocking read() of 1 byte, and if
# we succeed, we put it back and signal "yes, Virginia, there is still
# stuff out there"
#
# We could just use sysread and leave the socket buffer with the second
# message, and then use IO::Select as intended, and previous versions of
# this code did that (check the git history for this file), but
# performance suffers, about 20/30% slower, mostly because we do a lot
# of "read one line", where <$sock> beats the crap of anything you can
# write on Perl-land.
#
sub __try_read_sock {
  my $sock = shift;
  my $data = '';

  __fh_nonblocking($sock, 1);
  my $result = read($sock, $data, 1);
  my $err = 0 + $!;
  __fh_nonblocking($sock, 0);

  ## No errno?? This happens sometimes on my tests when the server
  ## timesout the client. I traced the system calls and I see the read()
  ## system call return 0 for EOF, but on this side of perl, we get
  ## undef...
  return 0 if !defined($result) && $err == 0;

  return $result unless $result;
  $sock->ungetc(ord($data));
  return 1;
}


### Copied from AnyEvent::Util
BEGIN {
  *__fh_nonblocking = ($^O eq 'MSWin32')
    ? sub($$) { ioctl $_[0], 0x8004667e, pack "L", $_[1]; }    # FIONBIO
    : sub($$) { fcntl $_[0], F_SETFL, $_[1] ? O_NONBLOCK : 0; };
}


##########################
# I take exception to that

sub __throw_reconnect {
  my ($self, $m) = @_;
  die bless(\$m, 'Redis::X::Reconnect') if $self->{reconnect};
  die $m;
}


1;

__END__

=head1 Pipeline management

=head2 wait_all_responses

Waits until all pending pipelined responses have been received, and invokes
the pipeline callback for each one.  See L</PIPELINING>.

=head1 Connection Handling

=head2 quit

  $r->quit;

The C<quit> method does not support pipelined operation.

=head2 ping

  $r->ping || die "no server?";

The C<ping> method does not support pipelined operation.

=head1 Commands operating on string values

=head2 set

  $r->set( foo => 'bar' );

  $r->setnx( foo => 42 );

=head2 get

  my $value = $r->get( 'foo' );

=head2 mget

  my @values = $r->mget( 'foo', 'bar', 'baz' );

=head2 incr

  $r->incr('counter');

  $r->incrby('tripplets', 3);

=head2 decr

  $r->decr('counter');

  $r->decrby('tripplets', 3);

=head2 exists

  $r->exists( 'key' ) && print "got key!";

=head2 del

  $r->del( 'key' ) || warn "key doesn't exist";

=head2 type

  $r->type( 'key' ); # = string

=head1 Commands operating on the key space

=head2 keys

  my @keys = $r->keys( '*glob_pattern*' );
  my $keys = $r->keys( '*glob_pattern*' ); # count of matching keys

Note that synchronous C<keys> calls in a scalar context return the number of
matching keys (not an array ref of matching keys as you might expect).  This
does not apply in pipelined mode: assuming the server returns a list of
keys, as expected, it is always passed to the pipeline callback as an array
ref.

=head2 randomkey

  my $key = $r->randomkey;

=head2 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=head2 dbsize

  my $nr_keys = $r->dbsize;

=head1 Commands operating on lists

See also L<Redis::List> for tie interface.

=head2 rpush

  $r->rpush( $key, $value );

=head2 lpush

  $r->lpush( $key, $value );

=head2 llen

  $r->llen( $key );

=head2 lrange

  my @list = $r->lrange( $key, $start, $end );

=head2 ltrim

  my $ok = $r->ltrim( $key, $start, $end );

=head2 lindex

  $r->lindex( $key, $index );

=head2 lset

  $r->lset( $key, $index, $value );

=head2 lrem

  my $modified_count = $r->lrem( $key, $count, $value );

=head2 lpop

  my $value = $r->lpop( $key );

=head2 rpop

  my $value = $r->rpop( $key );

=head1 Commands operating on sets

=head2 sadd

  my $ok = $r->sadd( $key, $member );

=head2 scard

  my $n_elements = $r->scard( $key );

=head2 sdiff

  my @elements = $r->sdiff( $key1, $key2, ... );
  my $elements = $r->sdiff( $key1, $key2, ... ); # ARRAY ref

=head2 sdiffstore

  my $ok = $r->sdiffstore( $dstkey, $key1, $key2, ... );

=head2 sinter

  my @elements = $r->sinter( $key1, $key2, ... );
  my $elements = $r->sinter( $key1, $key2, ... ); # ARRAY ref

=head2 sinterstore

  my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

=head2 sismember

  my $bool = $r->sismember( $key, $member );

=head2 smembers

  my @elements = $r->smembers( $key );
  my $elements = $r->smembers( $key ); # ARRAY ref

=head2 smove

  my $ok = $r->smove( $srckey, $dstkey, $element );

=head2 spop

  my $element = $r->spop( $key );

=head2 spop

  my $element = $r->srandmember( $key );

=head2 srem

  $r->srem( $key, $member );

=head2 sunion

  my @elements = $r->sunion( $key1, $key2, ... );
  my $elements = $r->sunion( $key1, $key2, ... ); # ARRAY ref

=head2 sunionstore

  my $ok = $r->sunionstore( $dstkey, $key1, $key2, ... );


=head1 Multiple databases handling commands

=head2 select

  $r->select( $dbindex ); # 0 for new clients

=head2 move

  $r->move( $key, $dbindex );

=head2 flushdb

  $r->flushdb;

=head2 flushall

  $r->flushall;

=head1 Sorting

=head2 sort

  $r->sort("key BY pattern LIMIT start end GET pattern ASC|DESC ALPHA');

=head1 Persistence control commands

=head2 save

  $r->save;

=head2 bgsave

  $r->bgsave;

=head2 lastsave

  $r->lastsave;

=head2 shutdown

  $r->shutdown;

The C<shutdown> method does not support pipelined operation.

=head1 Remote server control commands

=head2 info

  my $info_hash = $r->info;

The C<info> method is unique in that it decodes the server's response into a
hashref, if possible.  This decoding happens in both synchronous and
pipelined modes.

=head1 Transaction-handling commands

=head2 multi

  $r->multi;

=head2 discard

  $r->discard;

=head2 exec

  my @individual_replies = $r->exec;

C<exec> has special behaviour when run in a pipeline: the C<$reply> argument
to the pipeline callback is an array ref whose elements are themselves
C<[$reply, $error]> pairs.  This means that you can accurately detect errors
yielded by any command in the transaction, and without any exceptions being
thrown.


=head1 PIPELINING

Usually, running a command will wait for a response.  However, if you're
doing large numbers of requests, it can be more efficient to use what Redis
calls I<pipelining>: send multiple commands to Redis without waiting for a
response, then wait for the responses that come in.

To use pipelining, add a coderef argument as the last argument to a command
method call:

  $r->set('foo', 'bar', sub {});

Pending responses to pipelined commands are processed in a single batch, as
soon as at least one of the following conditions holds:

=over 4

=item *

A non-pipelined (synchronous) command has been sent on the same connection

=item *

A pub/sub subscription command (one of C<subscribe>, C<unsubscribe>,
C<psubscribe>, or C<punsubscribe>) is about to be sent on the same
connection.

=item *

The L</wait_all_responses> method is called explicitly.

=back

The coderef you supply to a pipelined command method is invoked once the
response is available.  It takes two arguments, C<$reply> and C<$error>.  If
C<$error> is defined, it contains the text of an error reply sent by the
Redis server.  Otherwise, C<$reply> is the non-error reply.  For almost all
commands, that means it's C<undef>, or a defined but non-reference scalar,
or an array ref of any of those; but see L</keys>, L</info>, and L</exec>.

Note the contrast with synchronous commands, which throw an exception on
receipt of an error reply, or return a non-error reply directly.

The fact that pipelined commands never throw an exception can be
particularly useful for Redis transactions; see L</exec>.


=head1 ENCODING

Since Redis knows nothing about encoding, we are forcing utf-8 flag on
all data received from Redis. This change is introduced in 1.2001
version. B<Please note> that this encoding option severely degrades
performance

You can disable this automatic encoding by passing an option to
new: C<< encoding => undef >>.

This allows us to round-trip utf-8 encoded characters correctly, but
might be problem if you push binary junk into Redis and expect to get it
back without utf-8 flag turned on.


=head1 AUTHORS

Pedro Melo, C<< <melo@cpan.org> >>

Original author and maintainer: Dobrica Pavlinusic, C<< <dpavlin at rot13.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-redis at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Redis>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Redis
    perldoc Redis::List
    perldoc Redis::Hash


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Redis>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Redis>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Redis>

=item * Search CPAN

L<http://search.cpan.org/dist/Redis>

=back


=head1 ACKNOWLEDGEMENTS

The following persons contributed to this project (alphabetical order):

=over 4

=item Dirk Vleugels

=item Flavio Poletti

=item Jeremy Zawodny

=item sunnavy at bestpractical.com

=item Thiago Berlitz Rondon

=item Ulrich Habel

=back


=head1 COPYRIGHT & LICENSE

Copyright 2009-2010 Dobrica Pavlinusic, all rights reserved.

Copyright 2011-2012 Pedro Melo, all rights reserved

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Redis
