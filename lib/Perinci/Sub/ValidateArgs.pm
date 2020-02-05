package Perinci::Sub::ValidateArgs;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;

use Data::Dmp;

use Exporter qw(import);
our @EXPORT_OK = qw(gen_args_validator);

# old name, deprecated
*gen_args_validator = \&gen_args_validator_from_meta;

# XXX cache key should also contain data_term
#my %dsah_compile_cache; # key = schema (C<string> or R<refaddr>), value = compilation result

our %SPEC;

$SPEC{gen_args_validator_from_meta} = {
    v => 1.1,
    summary => 'Generate argument validator from Rinci function metadata',
    description => <<'_',

If you don't intend to reuse the generated validator, you can also use
`validate_args_using_meta`.

_
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
sub gen_args_validator_from_meta {
    my %args = @_;

    my $meta = $args{meta};
    unless ($meta) {
        my @caller = caller(1) or die "Call gen_args_validator_from_meta() inside ".
            "your function or provide 'meta'";
        my ($pkg, $func) = $caller[3] =~ /(.+)::(.+)/;
        $meta = ${"$pkg\::SPEC"}{$func}
            or die "No metadata for $caller[3]";
    }
    my $args_as = $meta->{args_as} // 'hash';
    my $meta_args = $meta->{args} // {};
    my @meta_args = sort keys %$meta_args;

    my @code;
    my @modules_for_all_args;
    my @mod_stmts;

    my $use_dpath;

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
    my $addcode_validator = sub {
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
        die "Incompatible Data::Sah version (cd v=$cd->{v}, expected 2)" unless $cd->{v} == 2;
        #    $dsah_compile_cache{$cache_key} = $cd;
        #}
        push @code, "        \$err = undef;\n";
        push @code, "        \$_sahv_dpath = [];\n" if $cd->{use_dpath};
        push @code, "        unless (\n";
        push @code, $cd->{result}, ") { ".$gencode_err->(400, "\"Validation failed for argument '$data_name': \$err\"")." }\n";
        for my $mod_rec (@{ $cd->{modules} }) {
            next unless $mod_rec->{phase} eq 'runtime';
            next if grep { ($mod_rec->{use_statement} && $_->{use_statement} && $_->{use_statement} eq $mod_rec->{use_statement}) ||
                               $_->{name} eq $mod_rec->{name} } @modules_for_all_args;
            push @modules_for_all_args, $mod_rec;
            push @mod_stmts, $plc->stmt_require_module($mod_rec)."\n";
        }
        if ($cd->{use_dpath}) {
            $use_dpath = 1;
        }
    };

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
            $addcode_validator->($arg_spec->{schema}, $arg_name, $term_arg) if $arg_spec->{schema};
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
        if (@arg_names && ($meta_args->{$arg_names[-1]}{slurpy} // $meta_args->{$arg_names[-1]}{greedy})) {
            my $pos = @arg_names - 1;
            push @code, "    # handle slurpy last arg\n";
            push @code, "    if (\@\$args >= $pos) { \$args->[$pos] = [splice \@\$args, $pos] }\n\n";
        }

        my $start_of_optional;
        for my $i (0..$#arg_names) {
            my $arg_name = $arg_names[$i];
            my $arg_spec = $meta_args->{$arg_name};
            if ($arg_spec->{req}) {
                if (defined $start_of_optional) {
                    die "Error in metadata: after a param is optional ".
                        "(#$start_of_optional) the rest (#$i) must also be optional";
                }
            } else {
                $start_of_optional //= $i;
            }
        }

        push @code, "    # check number of args\n";
        if ($start_of_optional) {
            push @code, "    if (\@\$args < $start_of_optional || \@\$args > ".(@arg_names).") { ".$gencode_err->(400, "\"Wrong number of arguments (expected $start_of_optional..".(@arg_names).", got \".(\@\$args).\")\"") . " }\n";
        } elsif (defined $start_of_optional) {
            push @code, "    if (\@\$args > ".(@arg_names).") { ".$gencode_err->(400, "\"Wrong number of arguments (expected 0..".(@arg_names).", got \".(\@\$args).\")\"") . " }\n";
        } else {
            push @code, "    if (\@\$args != ".(@arg_names).") { ".$gencode_err->(400, "\"Wrong number of arguments (expected ".(@arg_names).", got \".(\@\$args).\")\"") . " }\n";
        }
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
            } elsif (($arg_spec->{slurpy} // $arg_spec->{greedy}) && $i < $#arg_names) {
                die "Error in metadata: argument '$arg_name' has slurpy=1 ".
                    "but is not the last argument";
            }
            push @code, "    # check argument $arg_name\n";
            if (defined $arg_spec->{default}) {
                push @code, "    $term_arg //= ".dmp($arg_spec->{default}).";\n";
            }
            my $open_block;
            if (defined($start_of_optional) && $i >= $start_of_optional) {
                $open_block++;
                push @code, "    if (\@\$args > $i) {\n";
            }
            $addcode_validator->($arg_spec->{schema}, $arg_name, $term_arg) if $arg_spec->{schema};
            push @code, "    }\n" if $open_block;

            push @code, "\n";
        }
    } else {
        die "Unsupported args_as '$args_as'";
    }
    push @code, "    return undef;\n";
    push @code, "}\n";

    unshift @code, (
        "sub {\n",
        "    my \$args = shift;\n",
        "    my \$err;\n",
        ("    my \$_sahv_dpath;\n") x !!$use_dpath,
        "\n"
    );

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

 use Perinci::Sub::ValidateArgs qw(gen_args_validator_from_meta);

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
     state $validator = gen_args_validator_from_meta();
     my %args = @_;
     if (my $err = $validator->(\%args)) { return $err }

     ...
 }

or, if you want the validator to die on failure:

 ...
 sub foo {
     state $validator = gen_args_validator_from_meta(die => 1);
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
