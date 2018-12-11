use strict;
use warnings;

my $debug = $ENV{DEBUG_TOKENIZER};
my $no_tokenize = $ENV{NO_TOKENIZE};
my $no_unindent = $ENV{NO_UNINDENT};
my $no_linenums = $ENV{NO_LINENUMS};

######################################################################

sub getline {
    my $fh = shift;
    my $countref = shift;
    my $line = '';

    return undef if eof $fh;

    $$countref = 0 if $countref;

    while (<$fh>) {
        ${$countref}++ if $countref;

        if ($_ !~ m|\\\s*\R$|) {
            $line .= $_;
            last;
        }
        $line .= $`;
    }

    return $line;
}

use feature 'state';

##### Initial processing
#
# This is inspired from
# https://gcc.gnu.org/onlinedocs/cpp/Initial-processing.html
#

# The grammar defines the possible states as keys, and the values must be
# a list of structs, where each struct will can have a combination of the
# following keywords:
#
# lookup        value MUST be a regexp that is anchored to the start of the
#               current input string.  $' MUST be whatever shall be processed
#               in the next iteration.  $1 MAY contain what should be added to
#               the output string.
# plus          value MUST be a string that's added unconditionally to the
#               output string, after $1.
# remain        value MUST be a string that's unconditionally to become the
#               input string for the next iteration.
# next          value MUST be a string that's the state of the next iteration.
# die           value MUST be a string to output with 'die'
#
# The initial state is 'default'
my %grammar = (
    default => [ { lookup => qr/^((?:\\.|.)*?)(?=\s*\/|"|')/,
                                                        next => 'check'   },
                 { lookup => qr/^(.*\R)$/                                 } ],
    check   => [ { lookup => qr|^(")|,                  next => 'dquote'  },
                 { lookup => qr|^(')|,                  next => 'squote'  },
                 { lookup => qr|^\s*//.*(?=\R$)|,       next => 'default' },
                 { lookup => qr|^\s*/\*|,  plus => ' ', next => 'comment' },
                 { lookup => qr/^(\\.|.)/,              next => 'default' } ],
    comment => [ { lookup => qr/^(?:\\.|.)*?\*\/\h*/,   next => 'default' },
                 { remain => ''                                           } ],
    dquote  => [ { lookup => qr/^((?:\\.|.)*?")/,       next => 'default' },
                 { die => 'No matching end double quote(")'               } ],
    squote  => [ { lookup => qr/^((?:\\.|.)*?')/,       next => 'default' },
                 { die => "No matching end single quote(')"               } ]
);

sub C_initial_processing {
    my $fh = shift;
    my $countref = shift;
    state $state = 'default';
    my $output = undef;

    while (my $input = getline($fh, $countref)) {
        $output = '' unless defined $output;
        while ($input) {
            print STDERR "DEBUG: state $state at '$output' : '$input'\n" if $debug;
            my @instructions = @{$grammar{$state}};
            my $instruction;
            my $newoutput;
            my $nextinput;

            foreach (@instructions) {
                $instruction = $_;
                last unless $instruction->{lookup};
                if ($input =~ m|$instruction->{lookup}|) {
                    $newoutput = $1;
                    $nextinput = $';
                    last;
                }
                $instruction = undef;
            }

            die "Couldn't find any match in state $state"
                unless defined $instruction;

            # We know we found a match, so use the remaining parts of the
            # instruction.
            die $instruction->{die} if defined $instruction->{die};
            $state = $instruction->{next} if defined $instruction->{next};
            $output .= $newoutput if defined $newoutput;
            $output .= $instruction->{plus} if defined $instruction->{plus};
            $input = $nextinput if defined $nextinput;
            $input = $instruction->{remain} if defined $instruction->{remain};
        }
        last if $state eq 'default';
    }

    print STDERR "DEBUG: final line is '$output'\n" if $debug && defined $output;
    return $output;
}

##### Tokenize
#
# This is inspired from
# https://gcc.gnu.org/onlinedocs/cpp/Tokenization.html
#

my @token_re = (
    # Special treatment for '#include', as the '<headerfile>' is a string
    qr/^\h*(#)\h*(include)\h*(<[^>]*>)\h*$/,

    # Identifiers
    # Note that we allow the dollar sign, as VMS identifiers may include them
    qr/^\h*([_\$[:alpha:]][_\$[:alnum:]]*+)\h*/,

    # Numbers
    # The Tokenization page says this:
    #
    # Formally, preprocessing numbers begin with an optional period, a
    # required decimal digit, and then continue with any sequence of
    # letters, digits, underscores, periods, and exponents. Exponents
    # are the two-character sequences ‘e+’, ‘e-’, ‘E+’, ‘E-’, ‘p+’,
    # ‘p-’, ‘P+’, and ‘P-’. (The exponents that begin with ‘p’ or ‘P’
    # are used for hexadecimal floating-point constants.)
    #
    qr/^\h*(\.?\d(?:\w|\.|[EePp][-+])*+)\h*/,

    # Strings
    qr/^\h*("(?:\\.|.)*?")\h*/,
    qr/^\h*('(?:\\.|.)*?')\h*/,

    # Multi-character operators that look like punctuation, taken from
    # https://en.cppreference.com/w/c/language/operator_precedence
    qr/^\h*
       (
           \+\+
       |   --
       |   ->
       |   <<
       |   >>
       |   <=
       |   >=
       |   ==
       |   !=
       |   &&
       |   \|\|
       |   \+=
       |   \-=
       |   \*=
       |   \/=
       |   %=
       |   <<=
       |   >>=
       |   &=
       |   \^=
       |   \|=
       |   \#\#                 # Because preprocessor operator ##
       )
       \h*/x,

    # Everything else is taken as punktuation, i.e. treated as single
    # character tokens
    qr/^\h*(.)\h*/
);

sub C_tokenize {
    my $input = shift;
    my @output = ();
    my ($indent) = $input =~ /^(\h*)/;

    push @output, $indent if $no_unindent && $indent;

    while ($input) {
        if ($input =~ /^\h*(\R)$/) {
            push @output, $1;
            last;
        }

        foreach (@token_re) {
            my @matches = $input =~ $_;
            next unless @matches;
            push @output, @matches;
            $input = $';
            last;
        }
    }

    # Skip empty lines
    return '' if $output[0] =~ /^\R$/;

    # Otherwise, concatenate all tokens with exactly one space between each
    return join(' ', @output);
}

##### C line reader
#
# Bring it all together
#

sub C_line {
    my $fh = shift;
    my $countref = shift;

    my $line = C_initial_processing($fh, $countref);

    if (defined $line) {
        $line = C_tokenize($line) unless $no_tokenize;
    }

    return $line;
}

######################################################################

my $count;
my $linenum = 1;
while (defined(my $line = C_line(\*STDIN, \$count))) {
    next if $line eq '';
    $line =~ s|\R$||;
    if ($no_linenums) {
	printf "%s\n", $line;
    } else {
	printf "%05d: %s\n", $linenum, $line;
    }
    $linenum += $count;
}
exit 0;

