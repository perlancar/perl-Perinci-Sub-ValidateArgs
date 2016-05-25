package Perinci::Sub::ValidateArgs;

# NOIFBUILT
# DATE
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;

use Data::Dmp;

use Exporter qw(import);
our @EXPORT = qw(gen_args_validator);

my %dsah_compile_cache; # key = schema (C<string> or R<refaddr>), value = compilation result

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
        dies => {
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
        if ($meta->{result_naked}) {
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
        unless ($cd = $dsah_compile_cache{$cache_key}) {
            $cd = $plc->compile(
                schema       => $schema,
                data_name    => $data_name,
                data_term    => $data_term,
                err_term     => '$err',
                return_type  => 'str',
                indent_level => 2,
            );
            $dsah_compile_cache{$cache_key} = $cd;
        }
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
    push @code, "    my \$err;\n";
    push @code, "    my \$_sahv_dpath;\n";
    if ($args_as eq 'hash' || $args_as eq 'hashref') {
        push @code, "    my \$args = shift;\n";
        my $term_hash = '%$args';
        my $codegen_term_hashkey = sub { '$args->{\''.$_[0].'\'}' };
        push @code, "    # check unknown args\n";
        push @code, "    for (keys $term_hash) { unless (/\\A(".join("|", map { quotemeta } @meta_args).")\\z/) { ".$gencode_err->(400, '"Unknown argument \'$_\'"')." } }\n";
        push @code, "\n";

        for my $arg_name (@meta_args) {
            my $arg_spec = $meta_args->{$arg_name};
            my $term_arg = $codegen_term_hashkey->($arg_name);
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
    } else {
        die "Unsupported args_as '$args_as'";
    }
    push @code, "    return undef;\n";
    push @code, "}\n";

    my $code = join("", @mod_stmts, @code);
    if ($args{source}) {
        return $code;
    } else {
        my $sub = eval $code;
        die if $@;
        return $sub;
    }
}

1;
# ABSTRACT: Validate function arguments using schemas in Rinci function metadata

=head1 SYNOPSIS

 #IFUNBUILT
 use Perinci::Sub::ValidateArgs;
 #END IFUNBUILT

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
     my %args = @_; # VALIDATE_ARGS
     # IFUNBUILT
     if (my $err = validate_args(\%args)) { return $err }
     # END IFUNBUILT

     ...
 }


=head1 DESCRIPTION

This module (PSV for short) can be used to validate function arguments using
schema information in Rinci function metadata. Schemas will be checked using
L<Data::Sah> validators which are generated on-demand and then cached.

There are other ways if you want to validate function arguments using Sah
schemas. See L<Data::Sah::Manual::ParamsValidating>.


=head1 FUNCTIONS

All the functions are exported by default.

=head2 validate_args(\%args) => $err

Get Rinci function metadata from caller's C<%SPEC> package variable. Then create
(and cache) a set of L<Data::Sah> validators to check the value of each argument
in C<%args>. If there is an error, will return an error response C<$err> (or
die, if C<result_naked> metadata property is true). Otherwise will return undef.

Arguments in C<%args> will have their default values/coercions/filters applied,
so they are ready for use.

Currently only support C<< args_as => 'hash' >> (the default).


=head1 SEE ALSO

L<Rinci>, L<Data::Sah>

L<Dist::Zilla::Plugin::IfBuilt>

L<Dist::Zilla::Plugin::Rinci::Validate>
