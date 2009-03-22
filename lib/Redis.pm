package Redis;

use warnings;
use strict;

use IO::Socket::INET;
use Data::Dump qw/dump/;
use Carp qw/confess/;

=head1 NAME

Redis - The great new Redis!

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Pure perl bindings for L<http://code.google.com/p/redis/>

    use Redis;

    my $r = Redis->new();




=head1 FUNCTIONS

=head2 new

=cut

our $sock;
my $server = '127.0.0.1:6379';

sub new {
	my $class = shift;
	my $self = {};
	bless($self, $class);

	warn "# opening socket to $server";

	$sock ||= IO::Socket::INET->new(
		PeerAddr => $server,
		Proto => 'tcp',
	) || die $!;

	$self;
}

sub _sock_result {
	my $result = <$sock>;
	warn "# result: ",dump( $result );
	$result =~ s{\r\n$}{} || warn "can't find cr/lf";
	return $result;
}

sub _sock_result_bulk {
	my $len = <$sock>;
	warn "# len: ",dump($len);
	return undef if $len eq "nil\r\n";
	my $v;
	read($sock, $v, $len) || die $!;
	warn "# v: ",dump($v);
	my $crlf;
	read($sock, $crlf, 2); # skip cr/lf
	return $v;
}

sub _sock_ok {
	my $ok = <$sock>;
	confess dump($ok) unless $ok eq "+OK\r\n";
}

sub _sock_send {
	my $self = shift;
	print $sock join(' ',@_) . "\r\n";
	_sock_result();
}

sub _sock_send_bulk {
	my ( $self, $command, $key, $value ) = @_;
	print $sock "$command $key " . length($value) . "\r\n$value\r\n";
	_sock_ok();
}


=head1 Connection Handling

=head2 quit

  $r->quit;

=cut

sub quit {
	my $self = shift;

	close( $sock ) || warn $!;
}

=head2 ping

  $r->ping || die "no server?";

=cut

sub ping {
	print $sock "PING\r\n";
	my $pong = <$sock>;
	die "ping failed, got ", dump($pong) unless $pong eq "+PONG\r\n";
}

=head1 Commands operating on string values

=head2 set

  $r->set( foo => 'bar', $new );

=cut

sub set {
	my ( $self, $key, $value, $new ) = @_;
	$self->_sock_send_bulk( "SET" . ( $new ? 'NX' : '' ), $key, $value );
}

=head2 get

  my $value = $r->get( 'foo' );

=cut

sub get {
	my ( $self, $k ) = @_;
	print $sock "GET $k\r\n";
	_sock_result_bulk();
}

=head2 incr

  $r->incr('counter');
  $r->incr('tripplets', 3);

=cut

	

sub incr {
	my ( $self, $key, $value ) = @_;
	if ( defined $value ) {
		print $sock "INCRBY $key $value\r\n";
	} else {
		print $sock "INCR $key\r\n";
	}
	_sock_result();
}

=head2 decr

  $r->decr('counter');
  $r->decr('tripplets', 3);

=cut

sub decr {
	my ( $self, $key, $value ) = @_;
	if ( defined $value ) {
		print $sock "DECRBY $key $value\r\n";
	} else {
		print $sock "DECR $key\r\n";
	}
	_sock_result();
}

=head2 exists

  $r->exists( 'key' ) && print "got key!";

=cut

sub exists {
	my ( $self, $key ) = @_;
	print $sock "EXISTS $key\r\n";
	_sock_result();
}

=head2 del

  $r->del( 'key' ) || warn "key doesn't exist";

=cut

sub del {
	my ( $self, $key ) = @_;
	print $sock "DEL $key\r\n";
	_sock_result();
}

=head2 type

  $r->type( 'key' ); # = string

=cut

sub type {
	my ( $self, $key ) = @_;
	print $sock "TYPE $key\r\n";
	_sock_result();
}

=head1 Commands operating on the key space

=head2 keys

  my @keys = $r->keys( '*glob_pattern*' );

=cut

sub keys {
	my ( $self, $glob ) = @_;
	print $sock "KEYS $glob\r\n";
	return split(/\s/, _sock_result_bulk());
}

=head2 randomkey

  my $key = $r->randomkey;

=cut

sub randomkey {
	my ( $self ) = @_;
	print $sock "RANDOMKEY\r\n";
	_sock_result();
}

=head2 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=cut

sub rename {
	my ( $self, $old, $new, $nx ) = @_;
	print $sock "RENAME" . ( $nx ? 'NX' : '' ) . " $old $new\r\n";
	_sock_ok();
}

=head2 dbsize

  my $nr_keys = $r->dbsize;

=cut

sub dbsize {
	my ( $self ) = @_;
	print $sock "DBSIZE\r\n";
	_sock_result();
}

=head1 Commands operating on lists

=head2 rpush

  $r->rpush( $key, $value );

=cut

sub rpush {
	my ( $self, $key, $value ) = @_;
	$self->_sock_send_bulk('RPUSH', $key, $value);
}

=head2 lpush

  $r->lpush( $key, $value );

=cut

sub lpush {
	my ( $self, $key, $value ) = @_;
	$self->_sock_send_bulk('LPUSH', $key, $value);
}

=head2 llen

  $r->llen( $key );

=cut

sub llen {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'llen', $key );
}

=head1 AUTHOR

Dobrica Pavlinusic, C<< <dpavlin at rot13.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-redis at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Redis>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Redis


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


=head1 COPYRIGHT & LICENSE

Copyright 2009 Dobrica Pavlinusic, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Redis
