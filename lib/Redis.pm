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

sub _sock_read_bulk {
	my $len = <$sock>;
	warn "## bulk len: ",dump($len);
	return undef if $len eq "nil\r\n";
	my $v;
	read($sock, $v, $len) || die $!;
	warn "## bulk v: ",dump($v);
	my $crlf;
	read($sock, $crlf, 2); # skip cr/lf
	return $v;
}

sub _sock_result_bulk {
	my $self = shift;
	warn "## _sock_result_bulk ",dump( @_ );
	print $sock join(' ',@_) . "\r\n";
	_sock_read_bulk();
}

sub __sock_ok {
	my $ok = <$sock>;
	confess dump($ok) unless $ok eq "+OK\r\n";
}

sub _sock_send {
	my $self = shift;
	warn "## _sock_send ",dump( @_ );
	print $sock join(' ',@_) . "\r\n";
	_sock_result();
}

sub _sock_send_ok {
	my $self = shift;
	warn "## _sock_send_ok ",dump( @_ );
	print $sock join(' ',@_) . "\r\n";
	__sock_ok();
}

sub __sock_send_bulk_raw {
	my $self = shift;
	warn "## _sock_send_bulk ",dump( @_ );
	my $value = pop;
	print $sock join(' ',@_) . ' ' . length($value) . "\r\n$value\r\n";
}

sub _sock_send_bulk {
	__sock_send_bulk_raw( @_ );
	__sock_ok();
}

sub _sock_send_bulk_number {
	__sock_send_bulk_raw( @_ );
	my $v = _sock_result();
	confess $v unless $v =~ m{^\-?\d+$};
	return $v;
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
	my $self = shift;
	$self->_sock_result_bulk('GET', @_);
}

=head2 incr

  $r->incr('counter');
  $r->incr('tripplets', 3);

=cut

	

sub incr {
	my $self = shift;
	$self->_sock_send( 'INCR' . ( $#_ ? 'BY' : '' ), @_ );
}

=head2 decr

  $r->decr('counter');
  $r->decr('tripplets', 3);

=cut

sub decr {
	my $self = shift;
	$self->_sock_send( 'DECR' . ( $#_ ? 'BY' : '' ), @_ );
}

=head2 exists

  $r->exists( 'key' ) && print "got key!";

=cut

sub exists {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'EXISTS', $key );
}

=head2 del

  $r->del( 'key' ) || warn "key doesn't exist";

=cut

sub del {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'DEL', $key );
}

=head2 type

  $r->type( 'key' ); # = string

=cut

sub type {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'TYPE', $key );
}

=head1 Commands operating on the key space

=head2 keys

  my @keys = $r->keys( '*glob_pattern*' );

=cut

sub keys {
	my ( $self, $glob ) = @_;
	return split(/\s/, $self->_sock_result_bulk( 'KEYS', $glob ));
}

=head2 randomkey

  my $key = $r->randomkey;

=cut

sub randomkey {
	my ( $self ) = @_;
	$self->_sock_send( 'RANDOMKEY' );
}

=head2 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=cut

sub rename {
	my ( $self, $old, $new, $nx ) = @_;
	$self->_sock_send_ok( 'RENAME' . ( $nx ? 'NX' : '' ), $old, $new );
}

=head2 dbsize

  my $nr_keys = $r->dbsize;

=cut

sub dbsize {
	my ( $self ) = @_;
	$self->_sock_send('DBSIZE');
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
	$self->_sock_send( 'LLEN', $key );
}

=head2 lrange

  my @list = $r->lrange( $key, $start, $end );

=cut

sub lrange {
	my ( $self, $key, $start, $end ) = @_;
	my $size = $self->_sock_send('LRANGE', $key, $start, $end);

	confess $size unless $size > 0;
	$size--;

	my @list = ( 0 .. $size );
	foreach ( 0 .. $size ) {
		$list[ $_ ] = _sock_read_bulk();
	}

	warn "## lrange $key $start $end = [$size] ", dump( @list );
	return @list;
}

=head2 ltrim

  my $ok = $r->ltrim( $key, $start, $end );

=cut

sub ltrim {
	my ( $self, $key, $start, $end ) = @_;
	$self->_sock_send_ok( 'LTRIM', $key, $start, $end );
}

=head2 lindex

  $r->lindex( $key, $index );

=cut

sub lindex {
	my ( $self, $key, $index ) = @_;
	$self->_sock_result_bulk( 'LINDEX', $key, $index );
}

=head2 lset

  $r->lset( $key, $index, $value );

=cut

sub lset {
	my ( $self, $key, $index, $value ) = @_;
	$self->_sock_send_bulk( 'LSET', $key, $index, $value );
}

=head2 lrem

  my $modified_count = $r->lrem( $key, $count, $value );

=cut

sub lrem {
	my ( $self, $key, $count, $value ) = @_;
	$self->_sock_send_bulk_number( 'LREM', $key, $count, $value );
}

=head2 lpop

  my $value = $r->lpop( $key );

=cut

sub lpop {
	my ( $self, $key ) = @_;
	$self->_sock_result_bulk( 'lpop', $key );
}

=head2 rpop

  my $value = $r->rpop( $key );

=cut

sub rpop {
	my ( $self, $key ) = @_;
	$self->_sock_result_bulk( 'rpop', $key );
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
