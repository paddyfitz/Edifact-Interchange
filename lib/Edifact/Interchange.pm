package Edifact::Interchange;

use warnings;
use strict;
use 5.010;
use Carp;
use Encode;
use Edifact::Message;

=head1 NAME

Edifact::Interchange - The great new Edifact::Interchange!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

#  UNOA and UNOB "correspond to the basic ascii sets of iso 646 and iso 6937"
# Version 4 of edifact should extend this to unicode
our %encoding_map = (
    'UNOA' => 'ascii',
    'UNOB' => 'ascii',
    'UNOC' => 'iso-8859-1',
    'UNOD' => 'iso-8859-2',
    'UNOE' => 'iso-8859-5',
    'UNOF' => 'iso-8859-7',
);

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Edifact::Interchange;

    my $foo = Edifact::Interchange->new();
    $foo->parse($edifact_message);
    or
    $foo->parse_file($filename);
    ...


=head1 SUBROUTINES/METHODS

=head2 new

Create an Edifact::Interchange object

=cut

sub new {
    my $class       = shift;
    my $print_trace = shift;

    my $self = {};

    #    $self->{print} = $print_trace;

    bless $self, $class;
    return $self;
}

=head2 parse

parse the edifact interchange passed in the message

=cut

sub parse {
    my $self = shift;
    my $doc  = shift;
    $self->{separator} = {
        component => q{\:},
        data      => q{\+},
        decimal   => q{.},
        release   => q{\?},
        reserved  => q{ },
        segment   => q{\'},
    };
    $self->{sep_class} = '\:\+\'\?';
    if ( $doc =~ s/^UNA// ) {    # optional
        my $element = substr $doc, 0, 6, q{};
        $self->read_service_string_advice($element);
    }
    my @segments =
      split /(?<!$self->{separator}->{release})$self->{separator}->{segment}/,
      $doc;
    $self->{interchange} = [];
    $self->{messages}    = [];
    $self->{msg_cnt}     = 0;
    if ( $segments[0] =~ m/^UNB/ ) {

        my $hdr = shift @segments;
        my @hdr_fields =
          split /(?<!$self->{separator}->{release})$self->{separator}->{data}/,
          $hdr;
        push @{ $self->{interchange} },
          $self->interchange_header( @hdr_fields[ 1 .. $#hdr_fields ] );
    } else {
        croak 'Interchange does not begin with an Interchange header';
    }
    my $current_msg;
    while ( my $segment = shift @segments ) {
        my ( $tag, @data ) =
          split /(?<!$self->{separator}->{release})$self->{separator}->{data}/,
          $segment;
        if ( $tag eq 'UNH' ) {
            $current_msg = $self->message_header(@data);
            next;
        } elsif ( $tag eq 'UNT' ) {
            $self->message_trailer( $current_msg, @data );
            $current_msg = undef;
            next;
        } elsif ( $tag eq 'UNZ' ) {
            $self->interchange_trailer(@data);
            next;
        } elsif ( $tag eq 'UNG' ) {
            $self->message_group_header(@data);
            next;
        } elsif ( $tag eq 'UNE' ) {
            $self->message_group_trailer(@data);
            next;
        }

        $self->user_data_segment( $current_msg, $tag, @data );
    }
    return;
}

=head2 parse_file

Reads an edifact message from a file and parses it
Will strip the lineendings added to files by some suppliers

=cut

sub parse_file {
    my $self     = shift;
    my $filename = shift;
    $filename ||= 'SampleQuote3.txt';

    open my $fh, '<', $filename or croak "Cannot open $filename : $!";
    my @lines = <$fh>;
    close $fh;

    for (@lines) {
        chomp;
        s/\r$//;
    }
    my $msg;
    if ( @lines == 1 ) {
        $msg = $lines[0];
    } elsif ( @lines > 1 ) {
        $msg = join q{}, @lines;
    }
    if ($msg) {
        $self->parse($msg);
    }
    return;
}

=head2 user_data_segment

internal method for handling message data segments
pass to the current Edifact::Message object for fuller passing

=cut

sub user_data_segment {
    my ( $self, $msg, $tag, @data ) = @_;

    my $d = $self->split_components(@data);

    # un release data
    $msg->add_segment( $tag, $d );

    return;
}

=head2 message_header

create a new Edifact::Message object

=cut

sub message_header {
    my ( $self, @data ) = @_;

    my $msg = Edifact::Message->new( $self->split_components(@data) );

    #say 'message_header';

    return $msg;
}

=head2 message_trailer

End message add completed message to my messages array

=cut

sub message_trailer {
    my ( $self, $msg, @data ) = @_;

    #say 'Message Trailer';

    #say "   Count=$data[0]";
    #say "   Ref=$data[1]";
    $self->{msg_cnt}++;
    push @{ $self->{messages} }, $msg;
    return;
}

=head2 interchange_trailer

internal method to parse and validate the
interchange trailer

=cut

sub interchange_trailer {
    my ( $self, @data ) = @_;

    #say 'Interchange Trailer';

    #say "$data[0] messages";
    if ( $data[0] != $self->{msg_cnt} ) {
        carp "Message count error trailer says $data[0] I counted "
          . $self->{msg_cnt};
    }
    say "Ref:$data[1]";
    if ( $data[1] ne $self->{control_ref} ) {

        #    say "Trailer: $data[1]";
        #say "Header : ", $self->{control_ref};
        carp 'Error mismatched control refs Header:'
          . $self->{control_ref}
          . ' Trailer:'
          . $data[1];
    }

    #    $self->{messages} = $data[0];
    return;
}

=head2 read_service_string_advice

internal method to parse the service string advice
and set the separator values for the interchange
accordingly 

=cut

sub read_service_string_advice {
    my $self = shift;
    my $ssa  = shift;

    # The six characters represent
    # component data element separator :
    # Data element sep                 +
    # Decimal notation                 .
    # Release Indicator                ?
    # Reseved (space)
    # Segment terminator               '
    if ( $ssa eq q{:+.? '} ) {

        #say 'Standard Service String Advice';
        return;
    } else {

        #say 'Non standard Service String Advice';
        my @char = unpack 'C6', $ssa;
        foreach (@char) {
            $_ = quotemeta($_);
        }
        $self->{separator} = {
            component => $char[0],
            data      => $char[1],
            decimal   => $char[2],
            release   => $char[3],
            reserved  => $char[4],
            segment   => $char[5],
        };
        $self->{sep_class} = join q{}, $char[0], $char[1], $char[3], $char[5];
    }
    return;
}

=head2 split_components

internal method to split data field into components

=cut

sub split_components {
    my ( $self, @data ) = @_;
    my $d_arr = [];
    for my $data_field (@data) {
        my @components =
          split
          /(?<!$self->{separator}->{release})$self->{separator}->{component}/,
          $data_field;
        foreach (@components) {
            s/$self->{separator}->{release}([$self->{sep_class}])/$1/g;

            # convert data to utf-8
            $_ = $self->{enc}->decode($_);
        }
        push @{$d_arr}, \@components;
    }
    return $d_arr;
}

=head2 interchange_header

Internal method to parse the interchange header

=cut

sub interchange_header {
    my ( $self, @hdr ) = @_;
    $self->{control_ref} = $hdr[4];
    my $charencoding = 'iso-8859-1';
    my $syntax_id = substr $hdr[0], 0, 4;
    if ( exists $encoding_map{$syntax_id} ) {
        $charencoding = $encoding_map{$syntax_id};
    }
    $self->{enc} = find_encoding($charencoding);
    croak qq(encoding "$charencoding" not found) unless ref $self->{enc};
    my $interchange_header = $self->split_components(@hdr);

    # syntax identifier :: Syntax_id a4 'UNO'[ABC]:Syntax_version
    # interchange_sender :: Sender_id:id_code_qualifier[:Address]
    # interchange_recipient :: Recepient_id:code_qualifier[:Address]
    # DateTime of Prep : YYMMDD:HHMM
    # Interchange Control Ref
    # Password
    # Application Ref
    # [Priority Code]
    # [Ack Request]
    # [Comm Agreement ID]
    # [Test Indicator [ 1 == a test]]
    return $interchange_header;
}

=head2 message_group_header

internal method to parse the message group header
(Currently a nop )

=cut

sub message_group_header {
    my ( $self, @data ) = @_;

    #TBD parse data
    say 'message_group_header';

    return;
}

=head2 message_group_trailer

internal method to parse the message group trailer
(Currently a nop )

=cut

sub message_group_trailer {
    my ( $self, @data ) = @_;

    #TBD parse data
    #say 'message_group_trailer';

    return;
}

=head2 messages

Returns and array_ref of Edifact::Message objects representing
the contents of the interchange

=cut

sub messages {
    my $self = shift;
    if ( exists $self->{messages} ) {
        return $self->{messages};
    }
    return;
}

=head1 AUTHOR

Colin Campbell, C<< <colin.campbell at ptfs-europe.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-edifact-interchange at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Edifact-Interchange>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Edifact::Interchange


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Colin Campbell.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;    # End of Edifact::Interchange
