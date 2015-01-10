package Redis;

# ABSTRACT: Perl binding for Redis database
# VERSION
# AUTHORITY

use warnings;
use strict;

use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Socket::Timeout;
use IO::Select;
use IO::Handle;
use Fcntl qw( O_NONBLOCK F_SETFL );
use Errno ();
use Data::Dumper;
use Carp;
use Try::Tiny;
use Scalar::Util ();

use Redis::Sentinel;

use constant WIN32       => $^O =~ /mswin32/i;
use constant EWOULDBLOCK => eval {Errno::EWOULDBLOCK} || -1E9;
use constant EAGAIN      => eval {Errno::EAGAIN} || -1E9;
use constant EINTR       => eval {Errno::EINTR} || -1E9;
use constant BUFSIZE     => 4096;

sub _maybe_enable_timeouts {
    my ($self, $socket) = @_;
    $socket or return;
    exists $self->{read_timeout} || exists $self->{write_timeout}
      or return $socket;
    IO::Socket::Timeout->enable_timeouts_on($socket);
    defined $self->{read_timeout}
      and $socket->read_timeout($self->{read_timeout});
    defined $self->{write_timeout}
      and $socket->write_timeout($self->{write_timeout});
    $socket;
}

sub new {
  my ($class, %args) = @_;
  my $self = bless {}, $class;

  $self->{__buf} = '';
  $self->{debug} = $args{debug} || $ENV{REDIS_DEBUG};

  ## Deal with REDIS_SERVER ENV
  if ($ENV{REDIS_SERVER} && ! exists $args{sock} && ! exists $args{server} && ! exists $args{sentinel}) {
    if ($ENV{REDIS_SERVER} =~ m!^/!) {
      $args{sock} = $ENV{REDIS_SERVER};
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^unix:(.+)!) {
      $args{sock} = $1;
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^(?:tcp:)?(.+)!) {
      $args{server} = $1;
    }
  }

  defined $args{$_}
    and $self->{$_} = $args{$_} for 
      qw(password on_connect name no_auto_connect_on_new cnx_timeout
         write_timeout read_timeout sentinels_cnx_timeout sentinels_write_timeout
         sentinels_read_timeout no_sentinels_list_update wait_until_loaded);

  $self->{reconnect}     = $args{reconnect} || 0;
  $self->{every}         = $args{every} || 1000;

  if (exists $args{sock}) {
    $self->{server} = $args{sock};
    $self->{builder} = sub {
        my ($self) = @_;
        $self->_maybe_enable_timeouts(
            IO::Socket::UNIX->new(
                Peer => $self->{server},
                ( $self->{cnx_timeout} ? ( Timeout => $self->{cnx_timeout} ): () ),
            )
        );
    };
  } elsif ($args{sentinels}) {
      $self->{sentinels} = $args{sentinels};

      ref $self->{sentinels} eq 'ARRAY'
        or croak("'sentinels' param must be an ArrayRef");

      defined($self->{service} = $args{service})
        or croak("Need 'service' name when using 'sentinels'!");

      $self->{builder} = sub {
          my ($self) = @_;
          # try to connect to a sentinel
          my $status;
          foreach my $sentinel_address (@{$self->{sentinels}}) {
              my $sentinel = eval {
                  Redis::Sentinel->new(
                      server => $sentinel_address,
                      cnx_timeout   => (   exists $self->{sentinels_cnx_timeout}
                                         ? $self->{sentinels_cnx_timeout}   : 0.1),
                      read_timeout  => (   exists $self->{sentinels_read_timeout}
                                         ? $self->{sentinels_read_timeout}  : 1  ),
                      write_timeout => (   exists $self->{sentinels_write_timeout}
                                         ? $self->{sentinels_write_timeout} : 1  ),
                  )
              } or next;
              my $server_address = $sentinel->get_service_address($self->{service});
              defined $server_address
                or $status ||= "Sentinels don't know this service",
                   next;
              $server_address eq 'IDONTKNOW'
                and $status = "service is configured in one Sentinel, but was never reached",
                    next;

              # we found the service, set the server
              $self->{server} = $server_address;

              if (! $self->{no_sentinels_list_update} ) {
                  # move the elected sentinel at the front of the list and add
                  # additional sentinels
                  my $idx = 2;
                  my %h = ( ( map { $_ => $idx++ } @{$self->{sentinels}}),
                            $sentinel_address => 1,
                          );
                  $self->{sentinels} = [
                      ( sort { $h{$a} <=> $h{$b} } keys %h ), # sorted existing sentinels,
                      grep { ! $h{$_}; }                      # list of unknown
                      map { +{ @$_ }->{name}; }               # names of
                      $sentinel->sentinel(                    # sentinels 
                        sentinels => $self->{service}         # for this service
                      )
                  ];
              }
              
              return $self->_maybe_enable_timeouts(
                  IO::Socket::INET->new(
                      PeerAddr => $server_address,
                      Proto    => 'tcp',
                      ( $self->{cnx_timeout} ? ( Timeout => $self->{cnx_timeout} ) : () ),
                  )
              );
          }
          croak($status || "failed to connect to any of the sentinels");
      };
  } else {
    $self->{server} = exists $args{server} ? $args{server} : '127.0.0.1:6379';
    $self->{builder} = sub {
        my ($self) = @_;
        $self->_maybe_enable_timeouts(
            IO::Socket::INET->new(
                PeerAddr => $self->{server},
                Proto    => 'tcp',
                ( $self->{cnx_timeout} ? ( Timeout => $self->{cnx_timeout} ) : () ),
            )
        );
    };
  }

  $self->{is_subscriber} = 0;
  $self->{subscribers}   = {};

  $self->connect unless $args{no_auto_connect_on_new};

  return $self;
}

sub is_subscriber { $_[0]{is_subscriber} }

sub select {
  my $self = shift;
  my $database = shift;
  my $ret = $self->__std_cmd('select', $database, @_);
  $self->{current_database} = $database;
  $ret;
}

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

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  # If this is an EXEC command, in pipelined mode, and one of the commands
  # executed in the transaction yields an error, we must collect all errors
  # from that command, rather than throwing an exception immediately.
  my $uc_command = uc($command);
  my $collect_errors = $cb && $uc_command eq 'EXEC';

  if ($uc_command eq 'MULTI') {
      $self->{__inside_transaction} = 1;
  } elsif ($uc_command eq 'EXEC' || $uc_command eq 'DISCARD') {
      delete $self->{__inside_transaction};
      delete $self->{__inside_watch};
  } elsif ($uc_command eq 'WATCH') {
      $self->{__inside_watch} = 1;
  } elsif ($uc_command eq 'UNWATCH') {
      delete $self->{__inside_watch};
  }

  ## Fast path, no reconnect;
  $self->{reconnect}
    or return $self->__run_cmd($command, $collect_errors, undef, $cb, @_);

  my @cmd_args = @_;
  $self->__with_reconnect(
    sub {
      $self->__run_cmd($command, $collect_errors, undef, $cb, @cmd_args);
    }
  );
}

sub __with_reconnect {
  my ($self, $cb) = @_;

  ## Fast path, no reconnect
  $self->{reconnect}
    or return $cb->();

  return &try(
    $cb,
    catch {
      ref($_) eq 'Redis::X::Reconnect'
        or die $_;

      $self->{__inside_transaction} || $self->{__inside_watch}
        and croak("reconnect disabled inside transaction or watch");

      $self->connect;
      $cb->();
    }
  );
}

sub __run_cmd {
  my ($self, $command, $collect_errors, $custom_decode, $cb, @args) = @_;

  my $ret;
  my $wrapper = $cb && $custom_decode
    ? sub {
      my ($reply, $error) = @_;
      $cb->(scalar $custom_decode->($reply), $error);
    }
    : $cb || sub {
      my ($reply, $error) = @_;
      croak "[$command] $error, " if defined $error;
      $ret = $reply;
    };

  $self->__send_command($command, @args);
  push @{ $self->{queue} }, [$command, $wrapper, $collect_errors];

  return 1 if $cb;

  $self->wait_all_responses;
  return
      $custom_decode ? $custom_decode->($ret, !wantarray)
    : wantarray && ref $ret eq 'ARRAY' ? @$ret
    :                                    $ret;
}

sub wait_all_responses {
  my ($self) = @_;

  my $queue = $self->{queue};
  $self->wait_one_response while @$queue;

  return;
}

sub wait_one_response {
  my ($self) = @_;

  my $handler = shift @{ $self->{queue} };
  return unless $handler;

  my ($command, $cb, $collect_errors) = @$handler;
  $cb->($self->__read_response($command, $collect_errors));

  return;
}


### Commands with extra logic
sub quit {
  my ($self) = @_;
  return unless $self->{sock};

  croak "[quit] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  try {
    $self->wait_all_responses;
    $self->__send_command('QUIT');
  };

  $self->__close_sock() if $self->{sock};

  return 1;
}

sub shutdown {
  my ($self) = @_;
  $self->__is_valid_command('SHUTDOWN');

  croak "[shutdown] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  return unless $self->{sock};

  $self->wait_all_responses;
  $self->__send_command('SHUTDOWN');
  $self->__close_sock() || croak("Can't close socket: $!");

  return 1;
}

sub ping {
  my $self = shift;
  $self->__is_valid_command('PING');

  croak "[ping] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  return unless exists $self->{sock};

  $self->wait_all_responses;
  return scalar try {
    $self->__std_cmd('PING');
  }
  catch {
    $self->__close_sock();
    return;
  };
}

sub info {
  my $self = shift;
  $self->__is_valid_command('INFO');

  my $custom_decode = sub {
    my ($reply) = @_;
    return $reply if !defined $reply || ref $reply;
    return { map { split(/:/, $_, 2) } grep {/^[^#]/} split(/\r\n/, $reply) };
  };

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  ## Fast path, no reconnect
  return $self->__run_cmd('INFO', 0, $custom_decode, $cb, @_)
    unless $self->{reconnect};

  my @cmd_args = @_;
  $self->__with_reconnect(
    sub {
      $self->__run_cmd('INFO', 0, $custom_decode, $cb, @cmd_args);
    }
  );
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
  $self->__with_reconnect(
    sub {
      $self->__run_cmd('KEYS', 0, $custom_decode, $cb, @cmd_args);
    }
  );
}


### PubSub
sub wait_for_messages {
  my ($self, $timeout) = @_;

  my $s = IO::Select->new;

  my $count = 0;


  my $e;

  try {
    $self->__with_reconnect( sub {

      # the socket can be changed due to reconnection, so get it each time
      my $sock = $self->{sock};
      $s->remove($s->handles);
      $s->add($sock);

      while ($s->can_read($timeout)) {      
        my $has_stuff = $self->__try_read_sock($sock);
        # If the socket is ready to read but there is nothing to read, ( so
        # it's an EOF ), try to reconnect.
        defined $has_stuff
          or $self->__throw_reconnect('EOF from server');

        do {
          my ($reply, $error) = $self->__read_response('WAIT_FOR_MESSAGES');
          croak "[WAIT_FOR_MESSAGES] $error, " if defined $error;
          $self->__process_pubsub_msg($reply);
          $count++;

          # if __try_read_sock() return 0 (no data)
          # or undef ( socket became EOF), back to select until timeout
        } while ($self->{__buf} || $self->__try_read_sock($sock));
      }
    
    });

  } catch {
    $e = $_;
};

# if We had an error and it was not an EOF, die
defined $e && $e ne 'EOF from server'
  and die $e;

  return $count;
}

sub __subscription_cmd {
  my $self    = shift;
  my $pr      = shift;
  my $unsub   = shift;
  my $command = shift;
  my $cb      = pop;

  croak("Missing required callback in call to $command(), ")
    unless ref($cb) eq 'CODE';

  $self->wait_all_responses;

  my @subs = @_;
  $self->__with_reconnect(
    sub {
      $self->__throw_reconnect('Not connected to any server')
        unless $self->{sock};

      @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
        if $unsub;
      return unless @subs;

      $self->__send_command($command, @subs);

      my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
      return $self->__process_subscription_changes($command, \%cbs);
    }
  );
}

sub subscribe    { shift->__subscription_cmd('',  0, subscribe    => @_) }
sub psubscribe   { shift->__subscription_cmd('p', 0, psubscribe   => @_) }
sub unsubscribe  { shift->__subscription_cmd('',  1, unsubscribe  => @_) }
sub punsubscribe { shift->__subscription_cmd('p', 1, punsubscribe => @_) }

sub __process_unsubscribe_requests {
  my ($self, $cb, $pr, @unsubs) = @_;
  my $subs = $self->{subscribers};

  my @subs_to_unsubscribe;
  for my $sub (@unsubs) {
    my $key = "${pr}message:$sub";
    my $cbs = $subs->{$key} = [grep { $_ ne $cb } @{ $subs->{$key} }];
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
    croak "[$cmd] $error, " if defined $error;

    ## Deal with pending PUBLISH'ed messages
    if ($m->[0] =~ /^p?message$/) {
      $self->__process_pubsub_msg($m);
      next;
    }

    my ($key, $unsub) = $m->[0] =~ m/^(p)?(un)?subscribe$/;
    $key .= "message:$m->[1]";
    my $cb = delete $expected->{$key};

    push @{ $subs->{$key} }, $cb unless $unsub;

    $self->{is_subscriber} = $m->[2];
  }
}

sub __process_pubsub_msg {
  my ($self, $m) = @_;
  my $subs = $self->{subscribers};

  my $sub   = $m->[1];
  my $cbid  = "$m->[0]:$sub";
  my $data  = pop @$m;
  my $topic = defined $m->[2] ? $m->[2] : $sub;

  if (!exists $subs->{$cbid}) {
    warn "Message for topic '$topic' ($cbid) without expected callback, ";
    return;
  }

  $_->($data, $topic, $sub) for @{ $subs->{$cbid} };

  return 1;

}


### Mode validation
sub __is_valid_command {
  my ($self, $cmd) = @_;

  croak("Cannot use command '$cmd' while in SUBSCRIBE mode, ")
    if $self->{is_subscriber};
}


### Socket operations
sub connect {
  my ($self) = @_;
  delete $self->{sock};
  delete $self->{__inside_watch};
  delete $self->{__inside_transaction};

  # Suppose we have at least one command response pending, but we're about
  # to reconnect.  The new connection will never get a response to any of
  # the pending commands, so delete all those pending responses now.
  $self->{queue} = [];
  $self->{pid}   = $$;

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
    || croak("Could not connect to Redis server at $self->{server}: $!");

  $self->{__buf} = '';

  if (exists $self->{password}) {
    try { $self->auth($self->{password}) }
    catch {
      $self->{reconnect} = 0;
      croak("Redis server refused password");
    };
  }

  ## WIP: not sure if we need to do this before AUTH above...
  ## It all depends if AUTH also returns LOADING (theoretically, there
  ## is no need, password is configuration, not DB)
  if ($self->{wait_until_loaded}) {
    local $@;
    require Time::HiRes;
    while ( !eval{ $self->exists("42"); 1 } && $@ =~ m/LOADING/ ) { Time::HiRes::usleep(100_000); }
  }

  $self->__on_connection;

  return;
}

sub __close_sock {
  my ($self) = @_;
  $self->{__buf} = '';
  delete $self->{__inside_watch};
  delete $self->{__inside_transaction};
  return close(delete $self->{sock});
}

sub __on_connection {

    my ($self) = @_;

    # If we are in PubSub mode we shouldn't perform any command besides
    # (p)(un)subscribe
    if (! $self->{is_subscriber}) {
      defined $self->{name}
        and try {
            my $n = $self->{name};
            $n = $n->($self) if ref($n) eq 'CODE';
            $self->client_setname($n) if defined $n;
        };
  
      defined $self->{current_database}
        and $self->select($self->{current_database});
    }

    foreach my $topic (CORE::keys(%{$self->{subscribers}})) {
      if ($topic =~ /(p?message):(.*)$/ ) {
        my ($key, $channel) = ($1, $2);
        if ($key eq 'message') {
            $self->__send_command('subscribe', $channel);
            my (undef, $error) = $self->__read_response('subscribe');
            defined $error
              and croak "[subscribe] $error";
        } else {
            $self->__send_command('psubscribe', $channel);
            my (undef, $error) = $self->__read_response('psubscribe');
            defined $error
              and croak "[psubscribe] $error";
        }
      }
    }

    defined $self->{on_connect}
      and $self->{on_connect}->($self);

}


sub __send_command {
  my $self = shift;
  my $cmd  = uc(shift);
  my $deb  = $self->{debug};

  if ($self->{pid} != $$) {
    $self->connect;
  }

  my $sock = $self->{sock}
    || $self->__throw_reconnect('Not connected to any server');

  warn "[SEND] $cmd ", Dumper([@_]) if $deb;

  ## Encode command using multi-bulk format
  my @cmd     = split /_/, $cmd;
  my $n_elems = scalar(@_) + scalar(@cmd);
  my $buf     = "\*$n_elems\r\n";
  for my $bin (@cmd, @_) {
    utf8::downgrade($bin, 1)
      or croak "command sent is not an octet sequence in the native encoding (Latin-1). Consider using debug mode to see the command itself.";
    $buf .= defined($bin) ? '$' . length($bin) . "\r\n$bin\r\n" : "\$-1\r\n";
  }

  ## Check to see if socket was closed: reconnect on EOF
  my $status = $self->__try_read_sock($sock);
  $self->__throw_reconnect('Not connected to any server')
    unless defined $status;

  ## Send command, take care for partial writes
  warn "[SEND RAW] $buf" if $deb;
  while ($buf) {
    my $len = syswrite $sock, $buf, length $buf;
    $self->__throw_reconnect("Could not write to Redis server: $!")
      unless defined $len;
    substr $buf, 0, $len, "";
  }

  return;
}

sub __read_response {
  my ($self, $cmd, $collect_errors) = @_;

  croak("Not connected to any server") unless $self->{sock};

  local $/ = "\r\n";

  ## no debug => fast path
  return $self->__read_response_r($cmd, $collect_errors) unless $self->{debug};

  my ($result, $error) = $self->__read_response_r($cmd, $collect_errors);
  warn "[RECV] $cmd ", Dumper($result, $error);
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
        croak "[$command] $nested[1], " if defined $nested[1];
        push @list, $nested[0];
      }
    }
    return \@list, undef;
  }
  else {
    croak "unknown answer type: $type ($result), ";
  }
}

sub __read_line {
  my $self = $_[0];
  my $sock = $self->{sock};

  my $data = $self->__read_line_raw;
  croak("Error while reading from Redis server: $!")
    unless defined $data;

  chomp $data;
  warn "[RECV RAW] '$data'" if $self->{debug};

  my $type = substr($data, 0, 1, '');
  return ($type, $data);
}

sub __read_line_raw {
  my $self = $_[0];
  my $sock = $self->{sock};
  my $buf = \$self->{__buf};

  if (length $$buf) {
    my $idx = index($$buf, "\r\n");
    $idx >= 0 and return substr($$buf, 0, $idx + 2, '');
  }

  while (1) {
    my $bytes = sysread($sock, $$buf, BUFSIZE, length($$buf));
    next if !defined $bytes && $! == EINTR;
    return unless defined $bytes && $bytes;

    # start looking for \r\n where we stopped last time
    # extracting one is required to handle corner case
    # where \r\n are split and therefore read by two conseqent sysreads
    my $idx = index($$buf, "\r\n", length($$buf) - $bytes - 1);
    $idx >= 0 and return substr($$buf, 0, $idx + 2, '');
  }
}

sub __read_len {
  my ($self, $len) = @_;
  my $buf = \$self->{__buf};
  my $buflen = length($$buf);

  if ($buflen < $len) {
    my $to_read = $len - $buflen;
    while ($to_read > 0) {
      my $bytes = sysread($self->{sock}, $$buf, BUFSIZE, length($$buf));
      next if !defined $bytes && $! == EINTR;
      croak("Error while reading from Redis server: $!") unless defined $bytes;
      croak("Redis server closed connection") unless $bytes;
      $to_read -= $bytes;
    }
  }

  my $data = substr($$buf, 0, $len, '');
  chomp $data;
  warn "[RECV RAW] '$data'" if $self->{debug};

  return $data;
}

sub __try_read_sock {
  my ($self, $sock) = @_;
  my $data = '';

  while (1) {
      # WIN32 doesn't support MSG_DONTWAIT,
      # need to swith fh to nonblockng mode manually.
      # For Unix still use MSG_DONTWAIT because of fewer syscalls
      my ($res, $err);
      if (WIN32) {
          __fh_nonblocking_win32($sock, 1);
          $res = recv($sock, $data, BUFSIZE, 0);
          $err = 0 + $!;
          __fh_nonblocking_win32($sock, 0);
      } else {
          $res = recv($sock, $data, BUFSIZE, MSG_DONTWAIT);
          $err = 0 + $!;
      }

      if (defined $res) {
        ## have read some data
        if (length($data)) {
            $self->{__buf} .= $data;
            return 1;
        }

        ## no data but also no error means EOF
        return;
      }

      next if $err && $err == EINTR;

      ## Keep going if nothing there, but socket is alive
      return 0 if $err and ($err == EWOULDBLOCK or $err == EAGAIN);

      ## result is undef but err is 0? should never happen
      return if $err == 0;

      ## For everything else, there is Mastercard...
      croak("Unexpected error condition $err/$^O, please report this as a bug");
  }
}

## Copied from AnyEvent::Util
sub __fh_nonblocking_win32 {
    ioctl $_[0], 0x8004667e, pack "L", $_[1];
}

##########################
# I take exception to that

sub __throw_reconnect {
  my ($self, $m) = @_;
  die bless(\$m, 'Redis::X::Reconnect') if $self->{reconnect};
  die $m;
}


1;    # End of Redis.pm

__END__

=head1 SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis->new;

    my $redis = Redis->new(server => 'redis.example.com:8080');

    ## Set the connection name (requires Redis 2.6.9)
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => 'my_connection_name',
    );
    my $generation = 0;
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => sub { "cache-$$-".++$generation },
    );

    ## Use UNIX domain socket
    my $redis = Redis->new(sock => '/path/to/socket');

    ## Enable auto-reconnect
    ## Try to reconnect every 1s up to 60 seconds until success
    ## Die if you can't after that
    my $redis = Redis->new(reconnect => 60, every => 1_000_000);

    ## Try each 100ms upto 2 seconds (every is in microseconds)
    my $redis = Redis->new(reconnect => 2, every => 100_000);

    ## Enable connection timeout (in seconds)
    my $redis = Redis->new(cnx_timeout => 60);

    ## Enable read timeout (in seconds)
    my $redis = Redis->new(read_timeout => 0.5);

    ## Enable write timeout (in seconds)
    my $redis = Redis->new(write_timeout => 1.2);

    ## Connect via a list of Sentinels to a given service
    my $redis = Redis->new(sentinels => [ '127.0.0.1:12345' ], service => 'mymaster');

    ## Same, but with connection, read and write timeout on the sentinel hosts
    my $redis = Redis->new( sentinels => [ '127.0.0.1:12345' ], service => 'mymaster',
                            sentinels_cnx_timeout => 0.1,
                            sentinels_read_timeout => 1,
                            sentinels_write_timeout => 1,
                          );

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
    ## or
    $redis->wait_one_response();

    ## Or run a large batch of commands in a pipeline
    my %hash = _get_large_batch_of_commands();
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
    my $timeout = 10;
    $redis->wait_for_messages($timeout) while 1;

    ##  ... until some condition
    my $keep_going = 1; ## other code will set to false to quit
    $redis->wait_for_messages($timeout) while $keep_going;

    $redis->publish('topic_1', 'message');


=head1 DESCRIPTION

Pure perl bindings for L<http://redis.io/>

This version supports protocol 2.x (multi-bulk) or later of Redis available at
L<https://github.com/antirez/redis/>.

This documentation lists commands which are exercised in test suite, but
additional commands will work correctly since protocol specifies enough
information to support almost all commands with same piece of code with a
little help of C<AUTOLOAD>.


=head1 PIPELINING

Usually, running a command will wait for a response.  However, if you're doing
large numbers of requests, it can be more efficient to use what Redis calls
I<pipelining>: send multiple commands to Redis without waiting for a response,
then wait for the responses that come in.

To use pipelining, add a coderef argument as the last argument to a command
method call:

  $r->set('foo', 'bar', sub {});

Pending responses to pipelined commands are processed in a single batch, as
soon as at least one of the following conditions holds:

=over

=item *

A non-pipelined (synchronous) command is called on the same connection

=item *

A pub/sub subscription command (one of C<subscribe>, C<unsubscribe>,
C<psubscribe>, or C<punsubscribe>) is about to be called on the same
connection.

=item *

One of L</wait_all_responses> or L</wait_one_response> methods is called
explicitly.

=back

The coderef you supply to a pipelined command method is invoked once the
response is available.  It takes two arguments, C<$reply> and C<$error>.  If
C<$error> is defined, it contains the text of an error reply sent by the Redis
server.  Otherwise, C<$reply> is the non-error reply. For almost all commands,
that means it's C<undef>, or a defined but non-reference scalar, or an array
ref of any of those; but see L</keys>, L</info>, and L</exec>.

Note the contrast with synchronous commands, which throw an exception on
receipt of an error reply, or return a non-error reply directly.

The fact that pipelined commands never throw an exception can be particularly
useful for Redis transactions; see L</exec>.


=head1 ENCODING

There is no encoding feature anymore, it has been deprecated and finally
removed. This module consider that any data sent to the Redis server is a binary data.
And it doesn't do anything when getting data from the Redis server.

So, if you are working with character strings, you should pre-encode or post-decode it if needed !

=head1 METHODS

=head2 Constructors

=head3 new

    my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

    my $r = Redis->new( server => '192.168.0.1:6379', debug => 0 );
    my $r = Redis->new( server => '192.168.0.1:6379', encoding => undef );
    my $r = Redis->new( sock => '/path/to/sock' );
    my $r = Redis->new( reconnect => 60, every => 5000 );
    my $r = Redis->new( password => 'boo' );
    my $r = Redis->new( on_connect => sub { my ($redis) = @_; ... } );
    my $r = Redis->new( name => 'my_connection_name' );
    my $r = Redis->new( name => sub { "cache-for-$$" });

    my $redis = Redis->new(sentinels => [ '127.0.0.1:12345', '127.0.0.1:23456' ],
                           service => 'mymaster');

    ## Connect via a list of Sentinels to a given service
    my $redis = Redis->new(sentinels => [ '127.0.0.1:12345' ], service => 'mymaster');

    ## Same, but with connection, read and write timeout on the sentinel hosts
    my $redis = Redis->new( sentinels => [ '127.0.0.1:12345' ], service => 'mymaster',
                            sentinels_cnx_timeout => 0.1,
                            sentinels_read_timeout => 1,
                            sentinels_write_timeout => 1,
                          );

The C<< server >> parameter specifies the Redis server we should connect to,
via TCP. Use the 'IP:PORT' format. If no C<< server >> option is present, we
will attempt to use the C<< REDIS_SERVER >> environment variable. If neither of
those options are present, it defaults to '127.0.0.1:6379'.

Alternatively you can use the C<< sock >> parameter to specify the path of the
UNIX domain socket where the Redis server is listening.

Alternatively you can use the C<< sentinels >> parameter and the C<< service >>
parameter to specify a list of sentinels to contact and try to get the address
of the given service name. C<< sentinels >> must be an ArrayRef and C<< service
>> an Str.

The C<< REDIS_SERVER >> can be used for UNIX domain sockets too. The following
formats are supported:

=over

=item *

/path/to/sock

=item *

unix:/path/to/sock

=item *

127.0.0.1:11011

=item *

tcp:127.0.0.1:11011

=back

The C<< reconnect >> option enables auto-reconnection mode. If we cannot
connect to the Redis server, or if a network write fails, we enter retry mode.
We will try a new connection every C<< every >> microseconds (1 ms by
default), up-to C<< reconnect >> seconds.

Be aware that read errors will always thrown an exception, and will not trigger
a retry until the new command is sent.

If we cannot re-establish a connection after C<< reconnect >> seconds, an
exception will be thrown.

The C<< cnx_timeout >> option enables connection timeout. The Redis client will
wait at most that number of seconds (can be fractional) before giving up
connecting to a server.

The C<< sentinels_cnx_timeout >> option enables sentinel connection timeout.
When using the sentinels feature, Redis client will wait at most that number of
seconds (can be fractional) before giving up connecting to a sentinel.
B<Default>: 0.1

The C<< read_timeout >> option enables read timeout. The Redis client will wait
at most that number of seconds (can be fractional) before giving up when
reading from the server.

The C<< sentinels_read_timeout >> option enables sentinel read timeout. When
using the sentinels feature, the Redis client will wait at most that number of
seconds (can be fractional) before giving up when reading from a sentinel
server. B<Default>: 1

The C<< write_timeout >> option enables write timeout. The Redis client will wait
at most that number of seconds (can be fractional) before giving up when
reading from the server.

The C<< sentinels_write_timeout >> option enables sentinel write timeout. When
using the sentinels feature, the Redis client will wait at most that number of
seconds (can be fractional) before giving up when reading from a sentinel
server. B<Default>: 1

If your Redis server requires authentication, you can use the C<< password >>
attribute. After each established connection (at the start or when
reconnecting), the Redis C<< AUTH >> command will be send to the server. If the
password is wrong, an exception will be thrown and reconnect will be disabled.

You can also provide a code reference that will be immediately after each
successful connection. The C<< on_connect >> attribute is used to provide the
code reference, and it will be called with the first parameter being the Redis
object.

If the Redis server has just started, it will not be available to
execute your commands until it ends loading the database snapshot from
disk into memory. On those situations, most commands will return an error.
You can use the option C<< wait_until_loaded >> to force Redis.pm to not
return from connect until the server has finished loading.

Note: for now, due to the lack of support form the redis-server to wait
until the DB is loaded, this command is implemented using a test-sleep-loop,
wasting your CPU.

You can also provide C<< no_auto_connect_on_new >> in which case C<<
new >> won't call C<< $obj->connect >> for you implicitly, you'll have
to do that yourself. This is useful for figuring out how long
connection setup takes so you can configure the C<< cnx_timeout >>
appropriately.

You can also provide C<< no_sentinels_list_update >>. By default (that is,
without this option), when successfully contacting a sentinel server, the Redis
client will ask it for the list of sentinels known for the given service, and
merge it with its list of sentinels (in the C<< sentinels >> attribute). You
can disable this behavior by setting C<< no_sentinels_list_update >> to a true
value.

You can also set a name for each connection. This can be very useful for
debugging purposes, using the C<< CLIENT LIST >> command. To set a connection
name, use the C<< name >> parameter. You can use both a scalar value or a
CodeRef. If the latter, it will be called after each connection, with the Redis
object, and it should return the connection name to use. If it returns a
undefined value, Redis will not set the connection name.

Please note that there are restrictions on the name you can set, the most
important of which is, no spaces. See the L<CLIENT SETNAME
documentation|http://redis.io/commands/client-setname> for all the juicy
details. This feature is safe to use with all versions of Redis servers. If C<<
CLIENT SETNAME >> support is not available (Redis servers 2.6.9 and above
only), the name parameter is ignored.

The C<< debug >> parameter enables debug information to STDERR, including all
interactions with the server. You can also enable debug with the C<REDIS_DEBUG>
environment variable.


=head2 Connection Handling

=head3 connect

  $r->connect();

Connects to the Redis server. This is done by default when the obect is
constructed using C<new()>, unless C<no_auto_connect_on_new> has been set. See
this option in the C<new()> constructor.

=head3 quit

  $r->quit;

Closes the connection to the server. The C<quit> method does not support
pipelined operation.

=head3 ping

  $r->ping || die "no server?";

The C<ping> method does not support pipelined operation.

=head3 client_list

  @clients = $r->client_list;

Returns list of clients connected to the server. See L<< CLIENT LIST
documentation|http://redis.io/commands/client-list >> for a description of the
fields and their meaning.

=head3 client_getname

  my $connection_name = $r->client_getname;

Returns the name associated with this connection. See L</client_setname> or the
C<< name >> parameter to L</new> for ways to set this name.

=head3 client_setname

  $r->client_setname('my_connection_name');

Sets this connection name. See the L<CLIENT SETNAME
documentation|http://redis.io/commands/client-setname> for restrictions on the
connection name string. The most important one: no spaces.

=head2 Pipeline management

=head3 wait_all_responses

Waits until all pending pipelined responses have been received, and invokes the
pipeline callback for each one.  See L</PIPELINING>.

=head3 wait_one_response

Waits until the first pending pipelined response has been received, and invokes
its callback.  See L</PIPELINING>.


=head2 Transaction-handling commands

B<Warning:> the behaviour of these commands when combined with pipelining is
still under discussion, and you should B<NOT> use them at the same time just
now.

You can L<follow the discussion to see the open issues with
this|https://github.com/melo/perl-redis/issues/17>.

=head3 multi

  $r->multi;

=head3 discard

  $r->discard;

=head3 exec

  my @individual_replies = $r->exec;

C<exec> has special behaviour when run in a pipeline: the C<$reply> argument to
the pipeline callback is an array ref whose elements are themselves C<[$reply,
$error]> pairs.  This means that you can accurately detect errors yielded by
any command in the transaction, and without any exceptions being thrown.


=head2 Commands operating on string values

=head3 set

  $r->set( foo => 'bar' );

  $r->setnx( foo => 42 );

=head3 get

  my $value = $r->get( 'foo' );

=head3 mget

  my @values = $r->mget( 'foo', 'bar', 'baz' );

=head3 incr

  $r->incr('counter');

  $r->incrby('tripplets', 3);

=head3 decr

  $r->decr('counter');

  $r->decrby('tripplets', 3);

=head3 exists

  $r->exists( 'key' ) && print "got key!";

=head3 del

  $r->del( 'key' ) || warn "key doesn't exist";

=head3 type

  $r->type( 'key' ); # = string


=head2 Commands operating on the key space

=head3 keys

  my @keys = $r->keys( '*glob_pattern*' );
  my $keys = $r->keys( '*glob_pattern*' ); # count of matching keys

Note that synchronous C<keys> calls in a scalar context return the number of
matching keys (not an array ref of matching keys as you might expect).  This
does not apply in pipelined mode: assuming the server returns a list of keys,
as expected, it is always passed to the pipeline callback as an array ref.

=head3 randomkey

  my $key = $r->randomkey;

=head3 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=head3 dbsize

  my $nr_keys = $r->dbsize;


=head2 Commands operating on lists

See also L<Redis::List> for tie interface.

=head3 rpush

  $r->rpush( $key, $value );

=head3 lpush

  $r->lpush( $key, $value );

=head3 llen

  $r->llen( $key );

=head3 lrange

  my @list = $r->lrange( $key, $start, $end );

=head3 ltrim

  my $ok = $r->ltrim( $key, $start, $end );

=head3 lindex

  $r->lindex( $key, $index );

=head3 lset

  $r->lset( $key, $index, $value );

=head3 lrem

  my $modified_count = $r->lrem( $key, $count, $value );

=head3 lpop

  my $value = $r->lpop( $key );

=head3 rpop

  my $value = $r->rpop( $key );


=head2 Commands operating on sets

=head3 sadd

  my $ok = $r->sadd( $key, $member );

=head3 scard

  my $n_elements = $r->scard( $key );

=head3 sdiff

  my @elements = $r->sdiff( $key1, $key2, ... );
  my $elements = $r->sdiff( $key1, $key2, ... ); # ARRAY ref

=head3 sdiffstore

  my $ok = $r->sdiffstore( $dstkey, $key1, $key2, ... );

=head3 sinter

  my @elements = $r->sinter( $key1, $key2, ... );
  my $elements = $r->sinter( $key1, $key2, ... ); # ARRAY ref

=head3 sinterstore

  my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

=head3 sismember

  my $bool = $r->sismember( $key, $member );

=head3 smembers

  my @elements = $r->smembers( $key );
  my $elements = $r->smembers( $key ); # ARRAY ref

=head3 smove

  my $ok = $r->smove( $srckey, $dstkey, $element );

=head3 spop

  my $element = $r->spop( $key );

=head3 srandmemeber

  my $element = $r->srandmember( $key );

=head3 srem

  $r->srem( $key, $member );

=head3 sunion

  my @elements = $r->sunion( $key1, $key2, ... );
  my $elements = $r->sunion( $key1, $key2, ... ); # ARRAY ref

=head3 sunionstore

  my $ok = $r->sunionstore( $dstkey, $key1, $key2, ... );

=head2 Commands operating on hashes

Hashes in Redis cannot be nested as in perl, if you want to store a nested
hash, you need to serialize the hash first. If you want to have a named
hash, you can use Redis-hashes. You will find an example in the tests
of this module t/01-basic.t

=head3 hset

Sets the value to a key in a hash.

  $r->hset('hashname', $key => $value); ## returns true on success

=head3 hget
  
Gets the value to a key in a hash.

  my $value = $r->hget('hashname', $key);

=head3 hexists
  
  if($r->hexists('hashname', $key) {
    ## do something, the key exists
  }
  else {
    ## the key does not exist
  }

=head3 hdel

Deletes a key from a hash

  if($r->hdel('hashname', $key)) {
    ## key is deleted
  }
  else {
    ## oops
  }

=head3 hincrby

Adds an integer to a value. The integer is signed, so a negative integer decrements.
  
  my $key = 'testkey';
  $r->hset('hashname', $key => 1); ## value -> 1
  my $increment = 1; ## has to be an integer
  $r->hincrby('hashname', $key => $increment); ## value -> 2
  $increment = 5;
  $r->hincrby('hashname', $key => $increment); ## value -> 7
  $increment = -1;
  $r->hincrby('hashname', $key => $increment); ## value -> 6

=head3 hsetnx

Adds a key to a hash unless it is not already set.

  my $key = 'testnx';
  $r->hsetnx('hashname', $key => 1); ## returns true
  $r->hsetnx('hashname', $key => 2); ## returns false because key already exists

=head3 hmset

Adds multiple keys to a hash.

  $r->hmset('hashname', 'key1' => 'value1', 'key2' => 'value2'); ## returns true on success


=head3 hmget

Returns multiple keys of a hash.

  my @values = $r->hmget('hashname', 'key1', 'key2');

=head3 hgetall

Returns the whole hash.

  my %hash = $r->hgetall('hashname');

=head3 hkeys

Returns the keys of a hash.

  my @keys = $r->hkeys('hashname');

=head3 hvals

Returns the values of a hash.

  my @values = $r->hvals('hashname');

=head3 hlen

Returns the count of keys in a hash.

  my $keycount = $r->hlen('hashname');



=head2 Sorting

=head3 sort

  $r->sort("key BY pattern LIMIT start end GET pattern ASC|DESC ALPHA');


=head2 Publish/Subscribe commands

When one of L</subscribe> or L</psubscribe> is used, the Redis object will
enter I<PubSub> mode. When in I<PubSub> mode only commands in this section,
plus L</quit>, will be accepted.

If you plan on using PubSub and other Redis functions, you should use two Redis
objects, one dedicated to PubSub and the other for regular commands.

All Pub/Sub commands receive a callback as the last parameter. This callback
receives three arguments:

=over

=item *

The published message.

=item *

The topic over which the message was sent.

=item *

The subscribed topic that matched the topic for the message. With L</subscribe>
these last two are the same, always. But with L</psubscribe>, this parameter
tells you the pattern that matched.

=back

See the L<Pub-Sub notes|http://redis.io/topics/pubsub> for more information
about the messages you will receive on your callbacks after each L</subscribe>,
L</unsubscribe>, L</psubscribe> and L</punsubscribe>.

=head3 publish

  $r->publish($topic, $message);

Publishes the C<< $message >> to the C<< $topic >>.

=head3 subscribe

  $r->subscribe(
      @topics_to_subscribe_to,
      my $savecallback = sub {
        my ($message, $topic, $subscribed_topic) = @_;
        ...
      },
  );

Subscribe one or more topics. Messages published into one of them will be
received by Redis, and the specified callback will be executed.

=head3 unsubscribe

  $r->unsubscribe(@topic_list, $savecallback);

Stops receiving messages via C<$savecallback> for all the topics in
C<@topic_list>. B<WARNING:> it is important that you give the same calleback
that you used for subscribtion. The value of the CodeRef must be the same, as
this is how internally the code identifies it.

=head3 psubscribe

  my @topic_matches = ('prefix1.*', 'prefix2.*');
  $r->psubscribe(@topic_matches, my $savecallback = sub { my ($m, $t, $s) = @_; ... });

Subscribes a pattern of topics. All messages to topics that match the pattern
will be delivered to the callback.

=head3 punsubscribe

  my @topic_matches = ('prefix1.*', 'prefix2.*');
  $r->punsubscribe(@topic_matches, $savecallback);

Stops receiving messages via C<$savecallback> for all the topics pattern
matches in C<@topic_list>. B<WARNING:> it is important that you give the same
calleback that you used for subscribtion. The value of the CodeRef must be the
same, as this is how internally the code identifies it.

=head3 is_subscriber

  if ($r->is_subscriber) { say "We are in Pub/Sub mode!" }

Returns true if we are in I<Pub/Sub> mode.

=head3 wait_for_messages

  my $keep_going = 1; ## Set to false somewhere to leave the loop
  my $timeout = 5;
  $r->wait_for_messages($timeout) while $keep_going;

Blocks, waits for incoming messages and delivers them to the appropriate
callbacks.

Requires a single parameter, the number of seconds to wait for messages. Use 0
to wait for ever. If a positive non-zero value is used, it will return after
that amount of seconds without a single notification.

Please note that the timeout is not a commitment to return control to the
caller at most each C<timeout> seconds, but more a idle timeout, were control
will return to the caller if Redis is idle (as in no messages were received
during the timeout period) for more than C<timeout> seconds.

The L</wait_for_messages> call returns the number of messages processed during
the run.


=head2 Persistence control commands

=head3 save

  $r->save;

=head3 bgsave

  $r->bgsave;

=head3 lastsave

  $r->lastsave;


=head2 Scripting commands

=head3 eval

  $r->eval($lua_script, $num_keys, $key1, ..., $arg1, $arg2);

Executes a Lua script server side.

Note that this commands sends the Lua script every time you call it. See
L</evalsha> and L</script_load> for an alternative.

=head3 evalsha

  $r->eval($lua_script_sha1, $num_keys, $key1, ..., $arg1, $arg2);

Executes a Lua script cached on the server side by its SHA1 digest.

See L</script_load>.

=head3 script_load

  my ($sha1) = $r->script_load($lua_script);

Cache Lua script, returns SHA1 digest that can be used with L</evalsha>.

=head3 script_exists

  my ($exists1, $exists2, ...) = $r->script_exists($scrip1_sha, $script2_sha, ...);

Given a list of SHA1 digests, returns a list of booleans, one for each SHA1,
that report the existence of each script in the server cache.

=head3 script_kill

  $r->script_kill;

Kills the currently running script.

=head3 script_flush

  $r->script_flush;

Flush the Lua scripts cache.


=head2 Remote server control commands

=head3 info

  my $info_hash = $r->info;

The C<info> method is unique in that it decodes the server's response into a
hashref, if possible. This decoding happens in both synchronous and pipelined
modes.

=head3 shutdown

  $r->shutdown;

The C<shutdown> method does not support pipelined operation.

=head3 slowlog

  my $nr_items = $r->slowlog("len");
  my @last_ten_items = $r->slowlog("get", 10);

The C<slowlog> command gives access to the server's slow log.


=head2 Multiple databases handling commands

=head3 select

  $r->select( $dbindex ); # 0 for new clients

=head3 move

  $r->move( $key, $dbindex );

=head3 flushdb

  $r->flushdb;

=head3 flushall

  $r->flushall;


=head1 ACKNOWLEDGEMENTS

The following persons contributed to this project (random order):

=over

=item *

Aaron Crane (pipelining and AUTOLOAD caching support)

=item *

Dirk Vleugels

=item *

Flavio Poletti

=item *

Jeremy Zawodny

=item *

sunnavy at bestpractical.com

=item *

Thiago Berlitz Rondon

=item *

Ulrich Habel

=item *

Ivan Kruglov

=item *

Steffen Mueller <smueller@cpan.org>

=back

=cut
