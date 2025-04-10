package RevBank::Cart::Entry;

use v5.32;
use warnings;
use experimental 'signatures';  # stable since v5.36

use Carp qw(carp croak);
use RevBank::Accounts;
use List::Util ();
use Scalar::Util ();

# Workaround for @_ in signatured subs being experimental and controversial
my $NONE = \do { my $dummy };
sub _arg_provided($a) {
    return 1 if not ref $a;
    return Scalar::Util::refaddr($a) != Scalar::Util::refaddr($NONE) 
}

sub new($class, $amount, $description, $attributes = {}) {
    $amount = RevBank::Amount->parse_string($amount) if not ref $amount;

    my $self = {
        quantity    => 1,
        amount      => $amount,  # negative = pay, positive = add money
        description => $description,
        attributes  => { %$attributes },
        account        => undef,
        contras     => [],
        caller      => List::Util::first(sub { !/^RevBank::Cart/ }, map { (caller $_)[3] } 1..10)
                       || (caller 1)[3],
        highlight   => 1,
    };

    return bless $self, $class;
}

sub add_contra($self, $account, $amount, $description, $display = undef) {
    # $display should be given for either ALL or NONE of the contras,
    # with the exception of contras with $amount == 0.00;

    $amount = RevBank::Amount->parse_string($amount) if not ref $amount;
    $account = RevBank::Accounts::assert_account($account);

    $description =~ s/\$you/$self->{account}/g if defined $self->{account};

    push @{ $self->{contras} }, {
        account     => $account,
        user        => $account,      # backwards compatibility until 2027-05-01
        amount      => $amount,       # should usually have opposite sign (+/-)
        description => $description,  # contra account's perspective
        display     => $display,      # interactive user's perspective
        highlight   => 1,
    };

    $self->attribute('changed', 1);

    return $self;  # for method chaining
}

sub has_attribute($self, $key) {
    return (
        exists      $self->{attributes}->{$key}
        and defined $self->{attributes}->{$key}
    );
}

sub attribute($self, $key, $new = $NONE) {
    my $ref = \$self->{attributes}->{$key};
    $$ref = $new if _arg_provided($new);
    return $$ref;
}

sub amount($self, $new = undef) {
    my $ref = \$self->{amount};
    if (defined $new) {
        $new = RevBank::Amount->parse_string($new) if not ref $new;
        $$ref = $new;
        $self->attribute('changed', 1);
        $self->{highlight_amount} = 1;
    }

    return $$ref;
}

sub quantity($self, $new = undef) {
    my $ref = \$self->{quantity};
    if (defined $new) {
        $new >= 0 or croak "Quantity must be positive";
        $$ref = $new;
        $self->attribute('changed', 1);
        $self->{highlight_quantity} = 1;
    }

    return $$ref;
}

sub multiplied($self) {
    return $self->{quantity} != 1;
}

sub contras($self) {
    # Shallow copy suffices for now, because there is no depth.
    return map +{ %$_ }, @{ $self->{contras} };
}

sub delete_contras($self) {
    $self->{contras} = [];
}

my $HI = "\e[37;1m";
my $LO = "\e[2m";
my $END = "\e[0m";

sub as_printable($self) {
    my @s;

    # Normally, the implied sign is "+", and an "-" is only added for negative
    # numbers. Here, the implied sign is "-", and a "+" is only added for
    # positive numbers.
    my $q = $self->{quantity};
    push @s, sprintf "%s%-4s%s" . "%s%8s%s" . " " . "%s%s%s", 
        ($self->{highlight} || $self->{highlight_quantity} ? $HI : $LO),
        ($q > 1 || $self->{highlight_quantity} ? "${q}x" : ""),
        ($self->{highlight} ? "" : $END),

        ($self->{highlight} || $self->{highlight_amount} ? $HI : $LO),
        $self->{amount}->string_flipped,
        ($self->{highlight} ? "" : $END),

        ($self->{highlight} ? $HI : $LO),
        $self->{description},
        $END;

    for my $c (@{ $self->{contras} }) {
        my $description;
        my $amount = $self->{amount};
        my $hidden = RevBank::Accounts::is_hidden($c->{account});
        my $fromto = $c->{amount}->cents < 0 ? "<-" : "->";
        $fromto .= " $c->{account}";

        if ($c->{display}) {
            $description =
                $hidden
                ? ($ENV{REVBANK_DEBUG} ? "($fromto:) $c->{display}" : $c->{display})
                : "$fromto: $c->{display}";

            $amount *= -1;
        } elsif ($hidden) {
            next unless $ENV{REVBANK_DEBUG};
            $description = "($fromto: $c->{description})";
        } else {
            $description = $fromto;
        }
        push @s, sprintf(
            "%s%15s %s%s",
            ($self->{highlight} || $c->{highlight} ? $HI : $LO),
            ($self->{amount} > 0 ? $c->{amount}->string_flipped("") : $c->{amount}->string),
            $description,
            $END,
        );
        delete $c->{highlight};
    }
    delete $self->@{qw(highlight highlight_quantity highlight_amount)};

    return @s;
}

sub as_loggable($self) {
    croak "Loggable called before set_account" if not defined $self->{account};

    my $quantity = $self->{quantity};

    my @s;
    for ($self, @{ $self->{contras} }) {
        my $total = $quantity * $_->{amount};

        my $description =
            $quantity == 1
            ? $_->{description}
            : sprintf("%s [%sx %s]", $_->{description}, $quantity, $_->{amount}->abs);

        push @s, sprintf(
            "%-12s %4s %3d %6s  # %s",
            $_->{account},
            ($total->cents > 0 ? 'GAIN' : $total->cents < 0 ? 'LOSE' : '===='),
            $quantity,
            $total->abs,
            $description
        );
    }

    return @s;
}

sub account($self, $new = undef) {
    if (defined $new) {
        croak "User can only be set once" if defined $self->{account};

        $self->{account} = $new;
        $self->{user} = $new;  # backwards compatibility until 2027-05-01
        $_->{description} =~ s/\$you/$new/g for $self, @{ $self->{contras} };
    }

    return $self->{account};
}

*user = \&account;  # backwards compatibility until 2027-05-01

sub sanity_check($self) {
    my @contras = $self->contras;

    my $sum = RevBank::Amount->new(
        List::Util::sum(map $_->{amount}->cents, $self, @contras)
    );

    if ($sum != 0) {
        local $ENV{REVBANK_DEBUG} = 1;
        my $message = join("\n",
            "BUG! (probably in $self->{caller})",
            "Unbalanced transactions are not possible in double-entry bookkeeping.",
            $self->as_printable,
            (
                !@contras
                ? "Use \$entry->add_contra to balance the transaction."
                : abs($sum) == 2 * abs($self->{amount})
                ? "Contras for positive value should be negative values and vice versa."
                : ()
            ),
        );
        RevBank::Plugins::call_hooks("log_error", "UNBALANCED ENTRY $message");
        croak $message;
    }

    return 1;
}

1;
