package Redis;

use warnings;
use strict;

use IO::Socket::INET;
use IO::Select;
use IO::Handle;
use Fcntl qw( O_NONBLOCK F_SETFL );
use Data::Dumper;
use Carp qw/confess/;
use Encode;
use Try::Tiny;

=head1 NAME

Redis - perl binding for Redis database

=cut

our $VERSION = '1.904';

=head1 SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis->new;
    
    my $redis = Redis->new(server => 'redis.example.com:8080');
    
    ## Disable the automatic utf8 encoding => much more performance
    my $redis = Redis->new(encoding => undef);
   
    ## Try to reconnect if the server closed connection, while 60 seconds.
    my $redis = Redis->new(reconnect => 60);

    ## Use all the regular Redis commands, they all accept a list of
    ## arguments
    ## See http://redis.io/commands for full list
    $redis->get('key');
    $redis->set('key' => 'value');
    $redis->sort('list', 'DESC');
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC});
    
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
additinal commands will work correctly since protocol specifies enough
information to support almost all commands with same peace of code with
a little help of C <AUTOLOAD> .


=head1 METHODS

=head2 new

    my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

    my $r = Redis->new( server => '192.168.0.1:6379', debug => 0 );
    my $r = Redis->new( server => '192.168.0.1:6379', encoding => undef );

=cut

sub new {
  my $class = shift;
  my $self  = {@_};

  $self->{debug} ||= $ENV{REDIS_DEBUG};
  $self->{encoding} = 'utf8'
    unless exists $self->{encoding};    ## default to lax utf8

  $self->{server} ||= $ENV{REDIS_SERVER} || '127.0.0.1:6379';

  $self->{is_subscriber} = 0;
  $self->{subscribers}   = {};
  $self->{reconnect} ||= 0;

  bless($self, $class);
  $self->{sock} = $self->__build_sock;
  
  return $self;
}

sub __build_sock {
  my $self = shift;
  return IO::Socket::INET->new(
    PeerAddr => $self->{server},
    Proto    => 'tcp',
  ) || confess("Could not connect to Redis server at $self->{server}: $!");
}

sub is_subscriber { $_[0]{is_subscriber} }


### we don't want DESTROY to fallback into AUTOLOAD
sub DESTROY { }


### Deal with common, general case, Redis commands
our $AUTOLOAD;

sub AUTOLOAD {
  my $self = shift;

  my $command = $AUTOLOAD;
  $command =~ s/.*://;
  $self->__is_valid_command($command);
 
  my @args = @_;

RUN_CMD:
  try {  
    return $self->__run_command($command, @args);
  } catch { 
    if ($self->{reconnect}) {
      sleep($self->{reconnect});
      $self->{sock} = $self->__build_sock;
      goto RUN_CMD;
    }
    return confess($_);
  };

}

sub __run_command {
  my $self = shift;
  my $command = shift;
  
  my $sock = $self->{sock} || confess("Not connected to any server");
  my $enc  = $self->{encoding};
  my $deb  = $self->{debug};

  ## PubSub commands use a different answer handling
  if (my ($pr, $unsub) = $command =~ /^(p)?(un)?subscribe$/i) {
    $pr = '' unless $pr;

    my $cb = pop;
    confess("Missing required callback in call to $command(), ")
      unless ref($cb) eq 'CODE';

    my @subs = @_;
    @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
      if $unsub;
    return unless @subs;

    $self->__send_command($command, @subs);

    my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
    return $self->__process_subscription_changes($command, \%cbs);
  }
  $self->__send_command($command, @_);
  return $self->__read_response($command);

}


### Commands with extra logic
sub quit {
  my ($self) = @_;

  $self->__send_command('QUIT');

  close(delete $self->{sock}) || confess("Can't close socket: $!");

  return 1;
}

sub shutdown {
  my ($self) = @_;

  $self->__send_command('SHUTDOWN');
  close(delete $self->{sock}) || confess("Can't close socket: $!");

  return 1;
}

sub ping {
  my ($self) = @_;
  return unless exists $self->{sock};

  my $reply;
  eval {
    $self->__send_command('PING');
    $reply = $self->__read_response('PING');
  };
  if ($@) {
    close(delete $self->{sock});
    return;
  }

  return $reply;
}

sub info {
  my ($self) = @_;
  $self->__is_valid_command('INFO');

  $self->__send_command('INFO');

  my $info = $self->__read_response('INFO');

  return {map { split(/:/, $_, 2) } split(/\r\n/, $info)};
}

sub keys {
  my $self = shift;
  $self->__is_valid_command('KEYS');

  $self->__send_command('KEYS', @_);

  my @keys = $self->__read_response('KEYS', \my $type);
  ## Support redis > 1.26
  return @keys if $type eq '*';

  ## Support redis <= 1.2.6
  return split(/\s/, $keys[0]) if $keys[0];
  return;
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
      my @m = $self->__read_response('WAIT_FOR_MESSAGES');
      $self->__process_pubsub_msg(\@m);
      $count++;
    }
  }

  return $count;
}

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
    my @m = $self->__read_response($cmd);

    ## Deal with pending PUBLISH'ed messages
    if ($m[0] =~ /^p?message$/) {
      $self->__process_pubsub_msg(\@m);
      next;
    }

    my ($key, $unsub) = $m[0] =~ m/^(p)?(un)?subscribe$/;
    $key .= "message:$m[1]";
    my $cb = delete $expected->{$key};

    push @{$subs->{$key}}, $cb unless $unsub;

    $self->{is_subscriber} = $m[2];
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

  return unless $self->{is_subscriber};
  return if $cmd =~ /^P?(UN)?SUBSCRIBE$/i;
  confess("Cannot use command '$cmd' while in SUBSCRIBE mode, ");
}


### Socket operations
sub __send_command {
  my $self = shift;
  my $cmd  = uc(shift);
  my $enc  = $self->{encoding};
  my $deb  = $self->{debug};

  warn "[SEND] $cmd ", Dumper([@_]) if $deb;

  ## Encode command using multi-bulk format
  my $n_elems = scalar(@_) + 1;
  my $buf     = "\*$n_elems\r\n";
  for my $elem ($cmd, @_) {
    my $bin = $enc ? encode($enc, $elem) : $elem;
    $buf .= defined($bin) ? '$' . length($bin) . "\r\n$bin\r\n" : "\$-1\r\n";
  }

  ## Send command, take care for partial writes
  warn "[SEND RAW] $buf" if $deb;
  my $sock = $self->{sock} || confess("Not connected to any server");
  while ($buf) {
    my $len = syswrite $sock, $buf, length $buf;
    confess("Could not write to Redis server: $!")
      unless $len;
    substr $buf, 0, $len, "";
  }

  return;
}

sub __read_response {
  my ($self, $cmd) = @_;

  confess("Not connected to any server") unless $self->{sock};

  local $/ = "\r\n";

  ## no debug => fast path
  return __read_response_r(@_) unless $self->{debug};

  if (wantarray) {
    my @r = __read_response_r(@_);
    warn "[RECV] $cmd ", Dumper(\@r);
    return @r;
  }
  else {
    my $r = __read_response_r(@_);
    warn "[RECV] $cmd ", Dumper($r);
    return $r;
  }
}

sub __read_response_r {
  my ($self, $command, $type_r) = @_;

  my ($type, $result) = $self->__read_line;
  $$type_r = $type if $type_r;

  if ($type eq '-') {
    confess "[$command] $result, ";
  }
  elsif ($type eq '+') {
    return $result;
  }
  elsif ($type eq '$') {
    return if $result < 0;
    return $self->__read_len($result + 2);
  }
  elsif ($type eq '*') {
    return if $result < 0;

    my @list;
    while ($result--) {
      push @list, scalar($self->__read_response_r($command));
    }
    return @list if wantarray;
    return \@list;
  }
  elsif ($type eq ':') {
    return $result;
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

  my $data;
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
  my $data;

  __fh_nonblocking($sock, 1);
  my $result = read($sock, $data, 1);
  __fh_nonblocking($sock, 0);

  return unless $result;
  $sock->ungetc(ord($data));
  return 1;
}


### Copied from AnyEvent::Util
BEGIN {
  *__fh_nonblocking = ($^O eq 'MSWin32')
    ? sub($$) { ioctl $_[0], 0x8004667e, pack "L", $_[1]; }    # FIONBIO
    : sub($$) { fcntl $_[0], F_SETFL, $_[1] ? O_NONBLOCK : 0; };
}


1;

__END__

=head1 Connection Handling

=head2 quit

  $r->quit;

=head2 ping

  $r->ping || die "no server?";

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

  $r->sadd( $key, $member );

=head2 srem

  $r->srem( $key, $member );

=head2 scard

  my $elements = $r->scard( $key );

=head2 sismember

  $r->sismember( $key, $member );

=head2 sinter

  $r->sinter( $key1, $key2, ... );

=head2 sinterstore

  my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

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

=head1 Remote server control commands

=head2 info

  my $info_hash = $r->info;


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

=item Jeremy Zawodny

=item sunnavy at bestpractical.com

=back


=head1 COPYRIGHT & LICENSE

Copyright 2009-2010 Dobrica Pavlinusic, all rights reserved.

Copyright 2011 Pedro Melo, all rights reserved

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Redis
