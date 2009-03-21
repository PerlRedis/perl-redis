package Redis;

use warnings;
use strict;

use IO::Socket::INET;
use Data::Dump qw/dump/;

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

  $r->set( foo => 'bar' );

=cut

sub set {
	my ( $self, $k, $v ) = @_;
	print $sock "SET $k " . length($v) . "\r\n$v\r\n";
	my $ok = <$sock>;
	die dump($ok) unless $ok eq "+OK\r\n";
}

=head2 get

  my $value = $r->get( 'foo' );

=cut

sub get {
	my ( $self, $k ) = @_;
	print $sock "GET $k\r\n";
	my $len = <$sock>;
	my $v;
	read($sock, $v, $len) || die $!;
	return $v;
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
