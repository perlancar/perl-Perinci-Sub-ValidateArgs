package Perinci::Sub::ValidateArgs;

# NOIFBUILT
# DATE
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;

use Data::Dmp;

use Exporter qw(import);
our @EXPORT_OK = qw(gen_args_validator);

# XXX cache key should also contain data_term
#my %dsah_compile_cache; # key = schema (C<string> or R<refaddr>), value = compilation result

our %SPEC;

$SPEC{gen_args_validator} = {
    v => 1.1,
    summary => 'Generate argument validator from Rinci function metadata',
    args => {
        meta => {
            schema => 'hash*', # XXX rinci::function_meta
            description => <<'_',

If not specified, will be searched from caller's `%SPEC` package variable.

_
        },
        source => {
            summary => 'Whether we want to get the source code instead',
            schema => 'bool',
            description => <<'_',

The default is to generate Perl validator code, compile it with `eval()`, and
return the resulting coderef. When this option is set to true, the generated
source string will be returned instead.

_
        },
        die => {
            summary => 'Whether validator should die or just return '.
                'an error message/response',
            schema => 'bool',
        },
    },
    result_naked => 1,
};
sub gen_args_validator {
    my %args = @_;

    my $meta = $args{meta};
    unless ($meta) {
        my @caller = caller(1) or die "Call gen_args_validator() inside ".
            "your function or provide 'meta'";
        my ($pkg, $func) = $caller[3] =~ /(.+)::(.+)/;
        $meta = ${"$pkg\::SPEC"}{$func}
            or die "No metadata for $caller[3]";
    }
    my $args_as = $meta->{args_as} // 'hash';
    my $meta_args = $meta->{args} // {};
    my @meta_args = sort keys %$meta_args;

    my @code;
    my %mod_stmts_cache;
    my @mod_stmts;

    my $gencode_err = sub {
        my ($status, $term_msg) = @_;
        if ($args{die}) {
            return "die $term_msg;";
        } elsif ($meta->{result_naked}) {
            # perhaps if result_naked=1, die by default?
            return "return $term_msg;";
        } else {
            return "return [$status, $term_msg];";
        }
    };
    my $gencode_validator = sub {
        state $plc = do {
            require Data::Sah;
            Data::Sah->new->get_compiler("perl");
        };
        my ($schema, $data_name, $data_term) = @_;
        my $cd;
        my $cache_key = ref($schema) ? "R$schema" : "S$schema";
        #unless ($cd = $dsah_compile_cache{$cache_key}) {
            $cd = $plc->compile(
                schema       => $schema,
                data_name    => $data_name,
                data_term    => $data_term,
                err_term     => '$err',
                return_type  => 'str',
                indent_level => 2,
            );
        #    $dsah_compile_cache{$cache_key} = $cd;
        #}
        push @code, "        \$err = undef;\n";
        push @code, "        \$_sahv_dpath = [];\n" if $cd->{use_dpath};
        push @code, "        unless (\n";
        push @code, $cd->{result}, ") { ".$gencode_err->(400, "\"Validation failed for argument '$data_name': \$err\"")." }\n";
        for (@{ $cd->{modules} }) {
            my $stmt;
            if (my $ms = $cd->{module_statements}{$_}) {
                $stmt = "$ms->[0] $_ (" . join(",", @{$ms->[1]}) . ");\n";
            } else {
                $stmt = "require $_;\n";
            }
            push @mod_stmts, $stmt unless $mod_stmts_cache{$stmt}++;
        }
    };

    push @code, "sub {\n";
    push @code, "    my \$args = shift;\n";
    push @code, "    my \$err;\n";
    push @code, "    my \$_sahv_dpath;\n";
    push @code, "\n";

    if ($args_as eq 'hash' || $args_as eq 'hashref') {
        push @code, "    # check unknown args\n";
        push @code, "    for (keys %\$args) { unless (/\\A(".join("|", map { quotemeta } @meta_args).")\\z/) { ".$gencode_err->(400, '"Unknown argument \'$_\'"')." } }\n";
        push @code, "\n";

        for my $arg_name (@meta_args) {
            my $arg_spec = $meta_args->{$arg_name};
            my $term_arg = "\$args->{'$arg_name'}";
            push @code, "    # check argument $arg_name\n";
            if (defined $arg_spec->{default}) {
                push @code, "    $term_arg //= ".dmp($arg_spec->{default}).";\n";
            }
            push @code, "    if (exists $term_arg) {\n";
            push @code, $gencode_validator->($arg_spec->{schema}, $arg_name, $term_arg) if $arg_spec->{schema};
            if ($arg_spec->{req}) {
                push @code, "    } else {\n";
                push @code, "        ".$gencode_err->(400, "\"Missing required argument '$arg_name'\"")."\n";
            }
            push @code, "    }\n";
        }

        push @code, "\n" if @meta_args;
    } elsif ($args_as eq 'array' || $args_as eq 'arrayref') {
        # map the arguments' position
        my @arg_names = sort {
            ($meta_args->{$a}{pos}//9999) <=> ($meta_args->{$b}{pos}//9999)
        } keys %$meta_args;
        if (@arg_names && $meta_args->{$arg_names[-1]}{greedy}) {
            my $pos = @arg_names - 1;
            push @code, "    # handle slurpy last arg\n";
            push @code, "    if (\@\$args >= $pos) { \$args->[$pos] = [splice \@\$args, $pos] }\n\n";
        }
        push @code, "    # check extraneous args\n";
        push @code, "    if (\@\$args > ".(@arg_names).") { ".$gencode_err->(400, "\"Too many arguments (expected ".(@arg_names).", got \".(\@\$args).\")\"") . " }\n";
        push @code, "\n";

        for my $i (0..$#arg_names) {
            my $arg_name = $arg_names[$i];
            my $arg_spec = $meta_args->{$arg_name};
            my $term_arg = "\$args->[$i]";
            if (!defined($arg_spec->{pos})) {
                die "Error in metadata: argument '$arg_name' does not ".
                    "have pos property set";
            } elsif ($arg_spec->{pos} != $i) {
                die "Error in metadata: argument '$arg_name' does not ".
                    "the correct pos value ($arg_spec->{pos}, should be $i)";
            } elsif ($arg_spec->{greedy} && $i < $#arg_names) {
                die "Error in metadata: argument '$arg_name' has greedy=1 ".
                    "but is not the last argument";
            }
            push @code, "    # check argument $arg_name\n";
            if (defined $arg_spec->{default}) {
                push @code, "    $term_arg //= ".dmp($arg_spec->{default}).";\n";
            }
            push @code, "    if (\@\$args > $i) {\n";
            push @code, $gencode_validator->($arg_spec->{schema}, $arg_name, $term_arg) if $arg_spec->{schema};
            if ($arg_spec->{req}) {
                push @code, "    } else {\n";
                push @code, "        ".$gencode_err->(400, "\"Missing required argument '$arg_name'\"")."\n";
            }
            push @code, "    }\n";
        }
    } else {
        die "Unsupported args_as '$args_as'";
    }
    push @code, "    return undef;\n";
    push @code, "}\n";

    my $code = join("", @mod_stmts, @code);
    if ($args{source}) {
        return $code;
    } else {
        #use String::LineNumber 'linenum'; say linenum $code;
        my $sub = eval $code;
        die if $@;
        return $sub;
    }
}

1;
# ABSTRACT: Validate function arguments using schemas in Rinci function metadata

=head1 SYNOPSIS

 use Perinci::Sub::ValidateArgs qw(gen_args_validator);

 our %SPEC;
 $SPEC{foo} = {
     v => 1.1,
     args => {
         a1 => {
            schema => 'int*',
            req => 1,
         },
         a2 => {
             schema => [array => of=>'int*'],
             default => 'peach',
         },
     },
     'x.func.validate_args' => 1,
 };
 sub foo {
     state $validator = gen_args_validator();
     my %args = @_;
     if (my $err = $validator->(\%args)) { return $err }

     ...
 }

or, if you want the validator to die on failure:

 ...
 sub foo {
     state $validator = gen_args_validator(die => 1);
     my %args = @_;
     $validator->(\%args);

     ...
 }


=head1 DESCRIPTION

This module (PSV for short) can be used to validate function arguments using
schema information in Rinci function metadata.

There are other ways if you want to validate function arguments using Sah
schemas. See L<Data::Sah::Manual::ParamsValidating>.


=head1 SEE ALSO

L<Rinci>, L<Data::Sah>

L<Dist::Zilla::Plugin::IfBuilt>

L<Dist::Zilla::Plugin::Rinci::Validate>
