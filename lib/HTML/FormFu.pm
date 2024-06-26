use strict;

package HTML::FormFu;

# ABSTRACT: HTML Form Creation, Rendering and Validation Framework

use Moose;
use MooseX::Attribute::Chained;

with 'HTML::FormFu::Role::Render',
    'HTML::FormFu::Role::CreateChildren',
    'HTML::FormFu::Role::GetProcessors',
    'HTML::FormFu::Role::ContainsElements',
    'HTML::FormFu::Role::ContainsElementsSharedWithField',
    'HTML::FormFu::Role::FormAndBlockMethods',
    'HTML::FormFu::Role::FormAndElementMethods',
    'HTML::FormFu::Role::FormBlockAndFieldMethods',
    'HTML::FormFu::Role::NestedHashUtils',
    'HTML::FormFu::Role::Populate',
    'HTML::FormFu::Role::CustomRoles';

use HTML::FormFu::Attribute qw(
    mk_attrs
    mk_attr_accessors
    mk_output_accessors
    mk_inherited_accessors
    mk_inherited_merging_accessors
);
use HTML::FormFu::Constants qw( $EMPTY_STR );
use HTML::FormFu::Constraint;
use HTML::FormFu::Exception;
use HTML::FormFu::FakeQuery;
use HTML::FormFu::Filter;
use HTML::FormFu::Inflator;
use HTML::FormFu::Localize;
use HTML::FormFu::ObjectUtil qw(
    form
    load_config_file            load_config_filestem
    clone                       stash
    parent
    _load_file
);
use HTML::FormFu::Util qw(
    DEBUG
    DEBUG_PROCESS
    DEBUG_CONSTRAINTS
    debug
    require_class               _get_elements
    xml_escape                  split_name
    _parse_args                 process_attrs
    _filter_components
);

use Clone ();
use List::Util 1.45 qw( first any none uniq );
use Scalar::Util qw( blessed weaken reftype );
use Carp qw( croak );

use overload (
    'eq'       => '_string_equals',
    '=='       => '_object_equals',
    '""'       => sub { return shift->render },
    'bool'     => sub {1},
    'fallback' => 1,
);

__PACKAGE__->mk_attr_accessors(qw( id action enctype method ));

for my $name ( qw(
    _elements
    _output_processors
    _valid_names
    _plugins
    _models
    ) )
{
    has $name => (
        is      => 'rw',
        default => sub { [] },
        lazy    => 1,
        isa     => 'ArrayRef',
    );
}

has languages => (
    is      => 'rw',
    default => sub { ['en'] },
    lazy    => 1,
    isa     => 'ArrayRef',
    traits  => ['Chained'],
);

has input => (
    is      => 'rw',
    default => sub { {} },
    lazy    => 1,
    isa     => 'HashRef',
    traits  => ['Chained'],
);

has _processed_params => (
    is      => 'rw',
    default => sub { {} },
    lazy    => 1,
    isa     => 'HashRef',
);

has form_error_message_class => (
    is      => 'rw',
    default => 'form_error_message',
    lazy    => 1,
);

our @MULTIFORM_SHARED = ( qw(
        javascript
        javascript_src
        indicator
        filename
        query_type
        force_error_message
        localize_class
        tt_module
        nested_name
        nested_subscript
        default_model
        tmp_upload_dir
        params_ignore_underscore
) );

for (@MULTIFORM_SHARED) {
    has $_ => (
        is     => 'rw',
        traits => ['Chained'],
    );
}

has submitted => ( is => 'rw', traits => ['Chained'] );
has query     => ( is => 'rw', traits => ['Chained'] );

has _auto_fieldset => ( is => 'rw' );

__PACKAGE__->mk_output_accessors(qw( form_error_message ));

*elements          = \&element;
*constraints       = \&constraint;
*filters           = \&filter;
*deflators         = \&deflator;
*inflators         = \&inflator;
*validators        = \&validator;
*transformers      = \&transformer;
*output_processors = \&output_processor;
*loc               = \&localize;
*plugins           = \&plugin;
*add_plugins       = \&add_plugin;

our $build_defaults = {
    action             => '',
    method             => 'post',
    filename           => 'form',
    render_method      => 'string',
    tt_args            => {},
    tt_module          => 'Template',
    query_type         => 'CGI',
    default_model      => 'DBIC',
    localize_class     => 'HTML::FormFu::I18N',
    auto_error_message => 'form_%s_%t',
    error_tag          => 'span',
};

sub BUILD {
    my ( $self, $args ) = @_;

    $self->populate($build_defaults);

    return;
}

sub auto_fieldset {
    my ( $self, $element_ref ) = @_;

    # if there's no arg, just return whether there's an auto_fieldset already
    return $self->_auto_fieldset if !$element_ref;

    # if the argument isn't a reference, assume it's just a "1" meaning true,
    # and use an empty hashref
    if ( !ref $element_ref ) {
        $element_ref = {};
    }

    $element_ref->{type} = 'Fieldset';

    $self->element($element_ref);

    $self->_auto_fieldset(1);

    return $self;
}

sub default_values {
    my ( $self, $default_ref ) = @_;

    for my $field ( @{ $self->get_fields } ) {
        my $name = $field->nested_name;
        next if !defined $name;
        next if !exists $default_ref->{$name};

        $field->default( $default_ref->{$name} );
    }

    return $self;
}

sub model {
    my ( $self, $model_name ) = @_;

    $model_name ||= $self->default_model;

    # search models already loaded
    for my $model ( @{ $self->_models } ) {
        return $model
            if $model->type =~ /\Q$model_name\E$/;
    }

    # class not found, try require-ing it
    my $class
        = $model_name =~ s/^\+//
        ? $model_name
        : "HTML::FormFu::Model::$model_name";

    require_class($class);

    my $model = $class->new(
        {   type   => $model_name,
            parent => $self,
        } );

    push @{ $self->_models }, $model;

    return $model;
}

sub process {
    my ( $self, $query ) = @_;

    $self->input(             {} );
    $self->_processed_params( {} );
    $self->_valid_names( [] );

    $self->clear_errors;

    $query ||= $self->query;

    if ( defined $query && !blessed($query) ) {
        $query = HTML::FormFu::FakeQuery->new( $self, $query );
    }

    # save it for further calls to process()
    if ($query) {
        DEBUG && debug( QUERY => $query );

        $self->query($query);
    }

    # run all elements pre_process() methods
    for my $elem ( @{ $self->get_elements } ) {
        $elem->pre_process;
    }

    # run all plugins pre_process() methods
    for my $plugin ( @{ $self->get_plugins } ) {
        $plugin->pre_process;
    }

    # run all elements process() methods
    for my $elem ( @{ $self->get_elements } ) {
        $elem->process;
    }

    # run all plugins process() methods
    for my $plugin ( @{ $self->get_plugins } ) {
        $plugin->process;
    }

    my $submitted;
    # refetch query in-case anything in pre_process/process changed it
    $query = $self->query;

    if ( defined $query ) {
        eval { my @params = $query->param };
        croak "Invalid query object: $@" if $@;

        $submitted = $self->_submitted($query);
    }

    DEBUG_PROCESS && debug( SUBMITTED => $submitted );

    $self->submitted($submitted);

    if ($submitted) {
        my %input;
        my @params = $query->param;

        for my $field ( @{ $self->get_fields } ) {
            my $name = $field->nested_name;

            next if !defined $name;
            next if none { $name eq $_ } @params;

            ## CGI wants you to use $query->multi_param($foo).
            ## doing so breaks CGI::Simple. So shoosh it up for now.
            local $CGI::LIST_CONTEXT_WARN = 0;

            if ( $field->nested ) {

                # call in list context so we know if there's more than 1 value
                my @values = $query->param($name);

                my $value
                    = @values > 1
                    ? \@values
                    : $values[0];

                $self->set_nested_hash_value( \%input, $name, $value );
            }
            else {
                my @values = $query->param($name);

                $input{$name}
                    = @values > 1
                    ? \@values
                    : $values[0];
            }
        }

        DEBUG && debug( INPUT => \%input );

        # run all field process_input methods
        for my $field ( @{ $self->get_fields } ) {
            $field->process_input( \%input );
        }

        $self->input( \%input );

        $self->_process_input;
    }

    # run all plugins post_process methods
    for my $elem ( @{ $self->get_elements } ) {
        $elem->post_process;
    }

    for my $plugin ( @{ $self->get_plugins } ) {
        $plugin->post_process;
    }

    return;
}

sub _submitted {
    my ( $self, $query ) = @_;

    my $indicator = $self->indicator;
    my $code;

    if ( defined($indicator) && ref $indicator ne 'CODE' ) {
        DEBUG_PROCESS && debug( INDICATOR => $indicator );

        $code = sub { return defined $query->param($indicator) };
    }
    elsif ( !defined $indicator ) {
        my @names = uniq
            grep {defined}
            map  { $_->nested_name } @{ $self->get_fields };

        DEBUG_PROCESS && debug( 'no indicator, checking fields...' => \@names );

        $code = sub {
            grep { defined $query->param($_) } @names;
        };
    }
    else {
        $code = $indicator;
    }

    return $code->( $self, $query );
}

sub _process_input {
    my ($self) = @_;

    $self->_build_params;

    $self->_process_file_uploads;

    $self->_filter_input;
    $self->_constrain_input;
    $self->_inflate_input   if !@{ $self->get_errors };
    $self->_validate_input  if !@{ $self->get_errors };
    $self->_transform_input if !@{ $self->get_errors };

    $self->_build_valid_names;

    return;
}

sub _build_params {
    my ($self) = @_;

    my %params;

    for my $field ( @{ $self->get_fields } ) {
        my $name = $field->nested_name;

        next if !defined $name;
        next if exists $params{$name};

        next
            if !$self->nested_hash_key_exists( $self->input, $name )
            && !$field->default_empty_value;

        my $input = $self->get_nested_hash_value( $self->input, $name );

        if ( ref $input eq 'ARRAY' ) {

            # can't clone upload filehandles
            # so create new arrayref of values
            $input = [@$input];
        }
        elsif ( !defined $input && $field->default_empty_value ) {
            $input = '';
        }

        $self->set_nested_hash_value( \%params, $name, $input, $name );
    }

    $self->_processed_params( \%params );

    DEBUG_PROCESS && debug( 'PROCESSED PARAMS' => \%params );

    return;
}

sub _process_file_uploads {
    my ($self) = @_;

    my @names = uniq
        grep {defined}
        map  { $_->nested_name }
        grep { $_->isa('HTML::FormFu::Element::File') } @{ $self->get_fields };

    if (@names) {
        my $query_class = $self->query_type;
        if ( $query_class !~ /^\+/ ) {
            $query_class = "HTML::FormFu::QueryType::$query_class";
        }
        require_class($query_class);

        my $params = $self->_processed_params;
        my $input  = $self->input;

        for my $name (@names) {
            next if !$self->nested_hash_key_exists( $input, $name );

            my $values = $query_class->parse_uploads( $self, $name );

            $self->set_nested_hash_value( $params, $name, $values );
        }
    }

    return;
}

sub _filter_input {
    my ($self) = @_;

    my $params = $self->_processed_params;

    for my $filter ( @{ $self->get_filters } ) {
        my $name = $filter->nested_name;

        next if !defined $name;
        next if !$self->nested_hash_key_exists( $params, $name );

        $filter->process( $self, $params );
    }

    return;
}

sub _constrain_input {
    my ($self) = @_;

    my $params = $self->_processed_params;

    for my $constraint ( @{ $self->get_constraints } ) {

        DEBUG_CONSTRAINTS && debug(
            'FIELD NAME'      => $constraint->field->nested_name,
            'CONSTRAINT TYPE' => $constraint->type,
        );

        $constraint->pre_process;

        my @errors = eval { $constraint->process($params) };

        DEBUG_CONSTRAINTS && debug( ERRORS => \@errors );
        DEBUG_CONSTRAINTS && debug( '$@'   => $@ );

        if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Constraint') ) {
            push @errors, $@;
        }
        elsif ($@) {
            push @errors, HTML::FormFu::Exception::Constraint->new;
        }

        for my $error (@errors) {
            if ( !$error->parent ) {
                $error->parent( $constraint->parent );
            }
            if ( !$error->constraint ) {
                $error->constraint($constraint);
            }

            $error->parent->add_error($error);
        }
    }

    return;
}

sub _inflate_input {
    my ($self) = @_;

    my $params = $self->_processed_params;

    for my $inflator ( @{ $self->get_inflators } ) {
        my $name = $inflator->nested_name;

        next if !defined $name;
        next if !$self->nested_hash_key_exists( $params, $name );
        next if any {defined} @{ $inflator->parent->get_errors };

        my $value = $self->get_nested_hash_value( $params, $name );

        my @errors;

        ( $value, @errors ) = eval { $inflator->process($value) };

        if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Inflator') ) {
            push @errors, $@;
        }
        elsif ($@) {
            push @errors, HTML::FormFu::Exception::Inflator->new;
        }

        for my $error (@errors) {
            $error->parent( $inflator->parent ) if !$error->parent;
            $error->inflator($inflator) if !$error->inflator;

            $error->parent->add_error($error);
        }

        $self->set_nested_hash_value( $params, $name, $value );
    }

    return;
}

sub _validate_input {
    my ($self) = @_;

    my $params = $self->_processed_params;

    for my $validator ( @{ $self->get_validators } ) {
        my $name = $validator->nested_name;

        next if !defined $name;
        next if !$self->nested_hash_key_exists( $params, $name );
        next if any {defined} @{ $validator->parent->get_errors };

        my @errors = eval { $validator->process($params) };

        if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Validator') ) {
            push @errors, $@;
        }
        elsif ($@) {
            push @errors, HTML::FormFu::Exception::Validator->new;
        }

        for my $error (@errors) {
            $error->parent( $validator->parent ) if !$error->parent;
            $error->validator($validator) if !$error->validator;

            $error->parent->add_error($error);
        }
    }

    return;
}

sub _transform_input {
    my ($self) = @_;

    my $params = $self->_processed_params;

    for my $transformer ( @{ $self->get_transformers } ) {
        my $name = $transformer->nested_name;

        next if !defined $name;
        next if !$self->nested_hash_key_exists( $params, $name );
        next if any {defined} @{ $transformer->parent->get_errors };

        my $value = $self->get_nested_hash_value( $params, $name );

        my (@errors) = eval { $transformer->process( $value, $params ) };

        if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Transformer') ) {
            push @errors, $@;
        }
        elsif ($@) {
            push @errors, HTML::FormFu::Exception::Transformer->new;
        }

        for my $error (@errors) {
            $error->parent( $transformer->parent ) if !$error->parent;
            $error->transformer($transformer) if !$error->transformer;

            $error->parent->add_error($error);
        }
    }

    return;
}

sub _build_valid_names {
    my ($self) = @_;

    my $params       = $self->_processed_params;
    my $skip_private = $self->params_ignore_underscore;
    my @errors       = $self->has_errors;
    my @names;
    my %non_param;

    for my $field ( @{ $self->get_fields } ) {
        my $name = $field->nested_name;

        next if !defined $name;
        next if $skip_private && $field->name =~ /^_/;

        if ( $field->non_param ) {
            $non_param{$name} = 1;
        }
        elsif ( $self->nested_hash_key_exists( $params, $name ) ) {
            push @names, $name;
        }
    }

    push @names, uniq
        grep { ref $params->{$_} ne 'HASH' }
        grep { !( $skip_private && /^_/ ) }
        grep { !exists $non_param{$_} }
        keys %$params;

    my %valid;

CHECK:
    for my $name (@names) {
        for my $error (@errors) {
            next CHECK if $name eq $error;
        }
        $valid{$name}++;
    }
    my @valid = keys %valid;

    $self->_valid_names( \@valid );

    return;
}

sub _hash_keys {
    my ( $hash, $subscript ) = @_;
    my @names;

    for my $key ( keys %$hash ) {
        if ( ref $hash->{$key} eq 'HASH' ) {
            push @names,
                map { $subscript ? "${key}[${_}]" : "$key.$_" }
                _hash_keys( $hash->{$key}, $subscript );
        }
        elsif ( ref $hash->{$key} eq 'ARRAY' ) {
            push @names,
                map { $subscript ? "${key}[${_}]" : "$key.$_" }
                _array_indices( $hash->{$key}, $subscript );
        }
        else {
            push @names, $key;
        }
    }

    return @names;
}

sub _array_indices {
    my ( $array, $subscript ) = @_;

    my @names;

    for my $i ( 0 .. $#{$array} ) {
        if ( ref $array->[$i] eq 'HASH' ) {
            push @names,
                map { $subscript ? "${i}[${_}]" : "$i.$_" }
                _hash_keys( $array->[$i], $subscript );
        }
        elsif ( ref $array->[$i] eq 'ARRAY' ) {
            push @names,
                map { $subscript ? "${i}[${_}]" : "$i.$_" }
                _array_indices( $array->[$i], $subscript );
        }
        else {
            push @names, $i;
        }
    }

    return @names;
}

sub submitted_and_valid {
    my ($self) = @_;

    return $self->submitted && !$self->has_errors;
}

sub params {
    my ($self) = @_;

    return {} if !$self->submitted;

    my @names = $self->valid;
    my %params;

    for my $name (@names) {
        my @values = $self->param($name);

        if ( @values > 1 ) {
            $self->set_nested_hash_value( \%params, $name, \@values );
        }
        else {
            $self->set_nested_hash_value( \%params, $name, $values[0] );
        }
    }

    return \%params;
}

sub param {
    my ( $self, $name ) = @_;

    croak 'param method is readonly' if @_ > 2;

    return if !$self->submitted;

    if ( @_ == 2 ) {
        return if !$self->valid($name);

        my $value
            = $self->get_nested_hash_value( $self->_processed_params, $name );

        return if !defined $value;

        if ( ref $value eq 'ARRAY' ) {
            return wantarray ? @$value : $value->[0];
        }
        else {
            return $value;
        }
    }

    # return a list of valid names, if no $name arg
    return $self->valid;
}

sub param_value {
    my ( $self, $name ) = @_;

    croak 'name parameter required' if @_ != 2;

    return undef    ## no critic (ProhibitExplicitReturnUndef);
        if !$self->valid($name);

    # this is guaranteed to always return a single value

    my $value = $self->get_nested_hash_value( $self->_processed_params, $name );

    return ref $value eq 'ARRAY'
        ? $value->[0]
        : $value;
}

sub param_array {
    my ( $self, $name ) = @_;

    croak 'name parameter required' if @_ != 2;

    # guaranteed to always return an arrayref

    return [] if !$self->valid($name);

    my $value = $self->get_nested_hash_value( $self->_processed_params, $name );

    return [] if !defined $value;

    return ref $value eq 'ARRAY'
        ? $value
        : [$value];
}

sub param_list {
    my ( $self, $name ) = @_;

    croak 'name parameter required' if @_ != 2;

    # guaranteed to always return an arrayref

    return if !$self->valid($name);

    my $value = $self->get_nested_hash_value( $self->_processed_params, $name );

    return if !defined $value;

    return ref $value eq 'ARRAY'
        ? @$value
        : $value;
}

sub valid {
    my $self = shift;

    return if !$self->submitted;

    my @valid = @{ $self->_valid_names };

    if (@_) {
        my $name = shift;

        return 1 if any { $name eq $_ } @valid;

        # not found - see if it's the name of a nested block
        my $parent;

        if ( defined $self->nested_name && $self->nested_name eq $name ) {
            $parent = $self;
        }
        else {
            ($parent)
                = first { $_->isa('HTML::FormFu::Element::Block') }
            @{ $self->get_all_elements( { nested_name => $name, } ) };
        }

        if ( defined $parent ) {
            my $fail = any {defined}
            map { @{ $_->get_errors } } @{ $parent->get_fields };

            return 1 if !$fail;
        }

        return;
    }

    # return a list of valid names, if no $name arg
    return @valid;
}

sub has_errors {
    my $self = shift;

    return if !$self->submitted;

    my @names = map { $_->nested_name }
        grep { @{ $_->get_errors } }
        grep { defined $_->nested_name } @{ $self->get_fields };

    if (@_) {
        my $name = shift;
        return 1 if any {/\Q$name/} @names;
        return;
    }

    # return list of names with errors, if no $name arg
    return @names;
}

sub add_valid {
    my ( $self, $key, $value ) = @_;

    croak 'add_valid requires arguments ($key, $value)' if @_ != 3;

    $self->set_nested_hash_value( $self->input, $key, $value );

    $self->set_nested_hash_value( $self->_processed_params, $key, $value );

    if ( none { $_ eq $key } @{ $self->_valid_names } ) {
        push @{ $self->_valid_names }, $key;
    }

    return $value;
}

sub _single_plugin {
    my ( $self, $arg_ref ) = @_;

    if ( !ref $arg_ref ) {
        $arg_ref = { type => $arg_ref };
    }
    elsif ( ref $arg_ref eq 'HASH' ) {

        # shallow clone
        $arg_ref = {%$arg_ref};
    }
    else {
        croak 'invalid args';
    }

    my $type = delete $arg_ref->{type};
    my @return;

    my @names = map { ref $_ ? @$_ : $_ }
        grep {defined} ( delete $arg_ref->{name}, delete $arg_ref->{names} );

    if (@names) {

        # add plugins to appropriate fields
        for my $x (@names) {
            for my $field ( @{ $self->get_fields( { nested_name => $x } ) } ) {
                my $new = $field->_require_plugin( $type, $arg_ref );
                push @{ $field->_plugins }, $new;
                push @return, $new;
            }
        }
    }
    else {

        # add plugin directly to form
        my $new = $self->_require_plugin( $type, $arg_ref );

        push @{ $self->_plugins }, $new;
        push @return, $new;
    }

    return @return;
}

around render => sub {
    my $orig = shift;
    my $self = shift;

    my $plugins = $self->get_plugins;

    for my $plugin (@$plugins) {
        $plugin->render;
    }

    my $output = $self->$orig;

    for my $plugin (@$plugins) {
        $plugin->post_render( \$output );
    }

    return $output;
};

sub render_data {
    my ( $self, $args ) = @_;

    my $render = $self->render_data_non_recursive(
        {   elements => [ map { $_->render_data } @{ $self->_elements } ],
            $args ? %$args : (),
        } );

    return $render;
}

sub render_data_non_recursive {
    my ( $self, $args ) = @_;

    my %render = (
        filename       => $self->filename,
        javascript     => $self->javascript,
        javascript_src => $self->javascript_src,
        attributes     => xml_escape( $self->attributes ),
        stash          => $self->stash,
        $args ? %$args : (),
    );

    $render{form} = \%render;
    weaken( $render{form} );

    $render{object} = $self;

    if ($self->force_error_message
        || ( $self->has_errors
            && defined $self->form_error_message ) )
    {
        $render{form_error_message} = xml_escape( $self->form_error_message );
        $render{form_error_message_class} = $self->form_error_message_class;
    }

    return \%render;
}

sub string {
    my ( $self, $args_ref ) = @_;

    $args_ref ||= {};

    my $html = $self->_string_form_start($args_ref);

    # form template

    $html .= "\n";

    for my $element ( @{ $self->get_elements } ) {

        # call render, so that child elements can use a different renderer
        my $element_html = $element->render;

        # skip Blank fields
        if ( length $element_html ) {
            $html .= $element_html . "\n";
        }
    }

    $html .= $self->_string_form_end($args_ref);
    $html .= "\n";

    return $html;
}

sub _string_form_start {
    my ( $self, $args_ref ) = @_;

    # start_form template

    my $render_ref
        = exists $args_ref->{render_data}
        ? $args_ref->{render_data}
        : $self->render_data_non_recursive;

    my $html = sprintf "<form%s>", process_attrs( $render_ref->{attributes} );

    if ( defined $render_ref->{form_error_message} ) {
        $html .= sprintf qq{\n<div class="%s">%s</div>},
            $render_ref->{form_error_message_class},
            $render_ref->{form_error_message},
            ;
    }

    if ( defined $render_ref->{javascript_src} ) {
        my $uri = $render_ref->{javascript_src};

        my @uris = ref $uri eq 'ARRAY' ? @$uri : ($uri);

        for my $uri (@uris) {
            $html .= sprintf
                qq{\n<script type="text/javascript" src="%s">\n</script>},
                $uri,
                ;
        }
    }

    if ( defined $render_ref->{javascript} ) {
        $html .= sprintf
            qq{\n<script type="text/javascript">\n%s\n</script>},
            $render_ref->{javascript},
            ;
    }

    return $html;
}

sub _string_form_end {
    my ($self) = @_;

    # end_form template

    return "</form>";
}

sub start {
    my $self = shift;

    if ( 'tt' eq $self->render_method ) {
        return $self->tt(
            {   filename    => 'start_form',
                render_data => $self->render_data_non_recursive,
            } );
    }
    else {
        return $self->_string_form_start(@_);
    }
}

sub end {
    my $self = shift;

    if ( 'tt' eq $self->render_method ) {
        return $self->tt(
            {   filename    => 'end_form',
                render_data => $self->render_data_non_recursive,
            } );
    }
    else {
        return $self->_string_form_end(@_);
    }
}

sub hidden_fields {
    my ($self) = @_;

    return join $EMPTY_STR,
        map { $_->render } @{ $self->get_fields( { type => 'Hidden' } ) };
}

sub output_processor {
    my ( $self, $arg ) = @_;
    my @return;

    if ( ref $arg eq 'ARRAY' ) {
        push @return, map { $self->_single_output_processor($_) } @$arg;
    }
    else {
        push @return, $self->_single_output_processor($arg);
    }

    return @return == 1 ? $return[0] : @return;
}

sub _single_output_processor {
    my ( $self, $arg ) = @_;

    if ( !ref $arg ) {
        $arg = { type => $arg };
    }
    elsif ( ref $arg eq 'HASH' ) {
        $arg = Clone::clone($arg);
    }
    else {
        croak 'invalid args';
    }

    my $type = delete $arg->{type};

    my $new = $self->_require_output_processor( $type, $arg );

    push @{ $self->_output_processors }, $new;

    return $new;
}

sub _require_output_processor {
    my ( $self, $type, $opt ) = @_;

    croak 'required arguments: $self, $type, \%options' if @_ != 3;

    croak "options argument must be hash-ref"
        if reftype($opt) ne 'HASH';

    my $class = $type;
    if ( not $class =~ s/^\+// ) {
        $class = "HTML::FormFu::OutputProcessor::$class";
    }

    $type =~ s/^\+//;

    require_class($class);

    my $object = $class->new(
        {   type   => $type,
            parent => $self,
        } );

    # handle default_args
    my $parent = $self->parent;

    if ( $parent && exists $parent->default_args->{output_processor}{$type} ) {
        %$opt
            = ( %{ $parent->default_args->{output_processor}{$type} }, %$opt );
    }

    $object->populate($opt);

    return $object;
}

sub get_output_processors {
    my $self = shift;
    my %args = _parse_args(@_);

    my @x = @{ $self->_output_processors };

    if ( exists $args{type} ) {
        @x = grep { $_->type eq $args{type} } @x;
    }

    return \@x;
}

sub get_output_processor {
    my $self = shift;

    my $x = $self->get_output_processors(@_);

    return @$x ? $x->[0] : ();
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 SYNOPSIS

Note: These examples make use of L<HTML::FormFu::Model::DBIC>. As of
C<HTML::FormFu> v02.005, the L<HTML::FormFu::Model::DBIC> module is
not bundled with C<HTML::FormFu> and is available in a stand-alone
distribution.

    use HTML::FormFu;

    my $form = HTML::FormFu->new;

    $form->load_config_file('form.yml');

    $form->process( $cgi_query );

    if ( $form->submitted_and_valid ) {
        # do something with $form->params
    }
    else {
        # display the form
        $template->param( form => $form );
    }

If you're using L<Catalyst>, a more suitable example might be:

    package MyApp::Controller::User;
    use Moose;
    extends 'Catalyst::Controller::HTML::FormFu';

    sub user : Chained CaptureArgs(1) {
        my ( $self, $c, $id ) = @_;

        my $rs = $c->model('Schema')->resultset('User');

        $c->stash->{user} = $rs->find( $id );

        return;
    }

    sub edit : Chained('user') Args(0) FormConfig {
        my ( $self, $c ) = @_;

        my $form = $c->stash->{form};
        my $user = $c->stash->{user};

        if ( $form->submitted_and_valid ) {

            $form->model->update( $user );

            $c->res->redirect( $c->uri_for( "/user/$id" ) );
            return;
        }

        $form->model->default_values( $user )
            if ! $form->submitted;

    }

Note: Because L</process> is automatically called for you by the Catalyst
controller; if you make any modifications to the form within your action
method, such as adding or changing elements, adding constraints, etc;
you must call L</process> again yourself before using L</submitted_and_valid>,
any of the methods listed under L</"SUBMITTED FORM VALUES AND ERRORS"> or
L</"MODIFYING A SUBMITTED FORM">, or rendering the form.

Here's an example of a config file to create a basic login form (all examples
here are L<YAML>, but you can use any format supported by L<Config::Any>),
you can also create forms directly in your perl code, rather than using an
external config file.

    ---
    action: /login
    indicator: submit
    auto_fieldset: 1

    elements:
      - type: Text
        name: user
        constraints:
          - Required

      - type: Password
        name: pass
        constraints:
          - Required

      - type: Submit
        name: submit

    constraints:
      - SingleValue

=head1 DESCRIPTION

L<HTML::FormFu> is a HTML form framework which aims to be as easy as
possible to use for basic web forms, but with the power and flexibility to
do anything else you might want to do (as long as it involves forms).

You can configure almost any part of formfu's behaviour and output. By
default formfu renders "XHTML 1.0 Strict" compliant markup, with as little
extra markup as possible, but with sufficient CSS class names to allow for a
wide-range of output styles to be generated by changing only the CSS.

All methods listed below (except L</new>) can either be called as a normal
method on your C<$form> object, or as an option in your config file. Examples
will mainly be shown in L<YAML> config syntax.

This documentation follows the convention that method arguments surrounded
by square brackets C<[]> are I<optional>, and all other arguments are
required.

=head1 BUILDING A FORM

=head2 new

Arguments: [\%options]

Return Value: $form

Create a new L<HTML::FormFu|HTML::FormFu> object.

Any method which can be called on the L<HTML::FormFu|HTML::FormFu> object may
instead be passed as an argument to L</new>.

    my $form = HTML::FormFu->new({
        action        => '/search',
        method        => 'GET',
        auto_fieldset => 1,
    });

=head2 load_config_file

Arguments: $filename

Arguments: \@filenames

Return Value: $form

Accepts a filename or list of file names, whose filetypes should be of any
format recognized by L<Config::Any>.

The content of each config file is passed to L</populate>, and so are added
to the form.

L</load_config_file> may be called in a config file itself, so as to allow
common settings to be kept in a single config file which may be loaded
by any form.

    ---
    load_config_file:
      - file1
      - file2

YAML multiple documents within a single file. The document start marker is
a line containing 3 dashes. Multiple documents will be applied in order,
just as if multiple filenames had been given.

In the following example, multiple documents are taken advantage of to
load another config file after the elements are added. (If this were
a single document, the C<load_config_file> would be called before
C<elements>, regardless of its position in the file).

    ---
    elements:
      - name: one
      - name: two

    ---
    load_config_file: ext.yml

Relative paths are resolved from the L</config_file_path> directory if
it is set, otherwise from the current working directory.

See L</BEST PRACTICES> for advice on organising config files.

=head2 config_callback

Arguments: \%options

If defined, the arguments are used to create a L<Data::Visitor::Callback>
object during L</load_config_file> which may be used to pre-process the
config before it is sent to L</populate>.

For example, the code below adds a callback to a form that will dynamically
alter any config value ending in ".yml" to end in ".yaml" when you call
L</load_config_file>:

    $form->config_callback({
      plain_value => sub {
        my( $visitor, $data ) = @_;
        s/\.yml/.yaml/;
      }
    });


Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

=head2 populate

Arguments: \%options

Return Value: $form

Each option key/value passed may be any L<HTML::FormFu|HTML::FormFu>
method-name and arguments.

Provides a simple way to set multiple values, or add multiple elements to
a form with a single method-call.

Attempts to call the method-names in a semi-intelligent order (see
the source of populate() in C<HTML::FormFu::ObjectUtil> for details).

=head2 default_values

Arguments: \%defaults

Return Value: $form

Set multiple field's default values from a single hash-ref.

The hash-ref's keys correspond to a form field's name, and the value is
passed to the field's L<default method|HTML::FormFu::_Field/default>.

This should be called after all fields have been added to the form, and
before L</process> is called (otherwise, call L</process> again before
rendering the form).

=head2 config_file_path

Arguments: $directory_name

L</config_file_path> defines where configuration files will be
searched for, if an absolute path is not given to
L</load_config_file>.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

Is an L<inheriting accessor|/INHERITING ACCESSORS>.

=head2 indicator

Arguments: $field_name

Arguments: \&coderef

If L</indicator> is set to a fieldname, L</submitted> will return true if
a value for that fieldname was submitted.

If L</indicator> is set to a code-ref, it will be called as a subroutine
with the two arguments C<$form> and C<$query>, and its return value will be
used as the return value for L</submitted>.

If L</indicator> is not set, L</submitted> will return true if a value for
any known fieldname was submitted.

=head2 auto_fieldset

Arguments: 1

Arguments: \%options

Return Value: $fieldset

This setting is suitable for most basic forms, and means you can generally
ignore adding fieldsets yourself.

Calling C<< $form->auto_fieldset(1) >> immediately adds a fieldset element to
the form. Thereafter, C<< $form->elements() >> will add all elements (except
fieldsets) to that fieldset, rather than directly to the form.

To be specific, the elements are added to the I<last> fieldset on the form,
so if you add another fieldset, any further elements will be added to that
fieldset.

Also, you may pass a hashref to auto_fieldset(), and this will be used
to set defaults for the first fieldset created.

A few examples and their output, to demonstrate:

2 elements with no fieldset.

    ---
    elements:
      - type: Text
        name: foo
      - type: Text
        name: bar

    <form action="" method="post">
      <div class="text">
        <input name="foo" type="text" />
      </div>
      <div class="text">
        <input name="bar" type="text" />
      </div>
    </form>

2 elements with an L</auto_fieldset>.

    ---
    auto_fieldset: 1
    elements:
      - type: Text
        name: foo
      - type: Text
        name: bar

    <form action="" method="post">
      <fieldset>
        <div class="text">
          <input name="foo" type="text" />
        </div>
        <div class="text">
          <input name="bar" type="text" />
        </div>
      </fieldset>
    </form>

The 3rd element is within a new fieldset

    ---
    auto_fieldset: { id: fs }
    elements:
      - type: Text
        name: foo
      - type: Text
        name: bar
      - type: Fieldset
      - type: Text
        name: baz

    <form action="" method="post">
      <fieldset id="fs">
        <div class="text">
          <input name="foo" type="text" />
        </div>
        <div class="text">
          <input name="bar" type="text" />
        </div>
      </fieldset>
      <fieldset>
        <div class="text">
          <input name="baz" type="text" />
        </div>
      </fieldset>
    </form>

Because of this behaviour, if you want nested fieldsets you will have to add
each nested fieldset directly to its intended parent.

    my $parent = $form->get_element({ type => 'Fieldset' });

    $parent->element('fieldset');

=head2 form_error_message

Arguments: $string

Normally, input errors cause an error message to be displayed alongside the
appropriate form field. If you'd also like a general error message to be
displayed at the top of the form, you can set the message with
L</form_error_message>.

To set the CSS class for the message, see L</form_error_message_class>.

To change the markup used to display the message, edit the
C<form_error_message> template file. See L</render_method>.

Is an L<output accessor|HTML::FormFu/OUTPUT ACCESSORS>.

=head2 force_error_message

If true, forces the L</form_error_message> to be displayed even if there are
no field errors.

=head2 default_args

Arguments: \%defaults

Set defaults which will be added to every element, constraint, etc. of the
given type which is subsequently added to the form.

For example, to make every C<Text> element automatically have a size of
C<10>, and make every C<Strftime> deflator automatically get its strftime
set to C<%d/%m/%Y>:

    default_args:
        elements:
            Text:
                size: 10
        deflators:
            Strftime:
                strftime: '%d/%m/%Y'

An example to make all DateTime elements automatically get an appropriate
Strftime deflator and a DateTime inflator:

    default_args:
        elements:
            DateTime:
                deflators:
                    type: Strftime
                    strftime: '%d-%m-%Y'
                inflators:
                    type: DateTime
                    parser:
                        strptime: '%d-%m-%Y'

=head3 Pseudo types

As a special case, you can also use the C<elements> keys C<Block>, C<Field>
and C<Input> to match any element which inherits from
L<HTML::FormFu::Element::Block> or which C<does>
L<HTML::FormFu::Role::Element::Field> or
L<HTML::FormFu::Role::Element::Input>.

=head3 Alternatives

Each C<elements> key can contain an C<any> list using the C<|> divider: e.g.

    # apply the given class to any Element of type Password or Button
    default_args:
        elements:
            'Password|Button':
                attrs:
                    class: novalidate

=head3 Match ancestor

Each C<elements> key list can contain a type starting with C<+> to only
match elements with an ancestor of the given type: e.g.

    # only apple the given class to an Input field within a Multi block
    default_args:
        elements:
            'Input|+Multi':
                attrs:
                    class: novalidate

=head3 Don't match ancestor

Each C<elements> key list can contain a type starting with C<-> to only
match elements who do not have an ancestor of the given type: e.g.

    # apply the given class only to Input fields that are not in a Multi block
    default_args:
        elements:
            'Input|-Multi':
                attrs:
                    class: validate

=head3 Order

The arguments are applied in least- to most-specific order:
C<Block>, C<Field>, C<Input>, C<$type>. Within each of these, arguments are
applied in order of shortest-first to longest-last.

The C<type> key must match the value returned by C<type>, e.g.
L<HTML::FormFu::Element/type>. If, for example, you have a custom element
outside of the C<HTML::FormFu::Element::*> namespace, which you load via
C<< $form->element({ type => '+My::Custom::Element' }) >>, the key given to
L</default_args> should B<not> include the leading C<+>, as that is
stripped-out of the returned C<type()> value. Example:

    # don't include the leading '+' here
    default_args:
        elements:
            'My::Custom::Element':
                attrs:
                    class: whatever

    # do include the leading '+' here
    elements:
        - type: +My::Custom::Element

=head3 Clashes

L</default_args> generates a single hashref to pass to L</populate>, merging
arguments for each type in turn - meaning L</populate> is only called once
in total - not once for each type.
Because scalar values are B<not> merged - this means later values will
override earlier values: e.g.

    # Normally, calling $field->add_attrs({ class => 'input' })
    # then calling      $field->add_attrs({ class => 'not-in-multi' })
    # would result in both values being retained:
    #           class="input not-in-multi"
    #
    # However, default_args() creates a single data-structure to pass once
    # to populate(), so any scalar values will overwrite earlier ones
    # before they reach populate().
    #
    # The below example would result in the longest-matching key
    # overwriting any others:
    #           class="not-in-multi"
    #
    default_args:
        elements:
            Input:
                add_attrs:
                    class: input
            'Input:-Multi':
                add_attrs:
                    class: not-in-multi

=head3 Strictness

Note: Unlike the proper methods which have aliases, for example L</elements>
which is an alias for L</element> - the keys given to C<default_args> must
be of the plural form, e.g.:

    default_args:
        elements:          {}
        deflators:         {}
        filters:           {}
        constraints:       {}
        inflators:         {}
        validators:        {}
        transformers:      {}
        output_processors: {}

=head2 javascript

If set, the contents will be rendered within a C<script> tag, inside the top
of the form.

=head2 javascript_src

Arguments: $url

Arguments: \@urls

Adds a C<script> tag for each URL, immediately before any L</javascript>
section.

=head2 stash

Arguments: [\%private_stash]

Return Value: \%stash

Provides a hash-ref in which you can store any data you might want to
associate with the form.

    ---
    stash:
      foo: value
      bar: value

=head2 elements

=head2 element

Arguments: $type

Arguments: \%options

Return Value: $element

Arguments: \@arrayref_of_types_or_options

Return Value: @elements

Adds a new element to the form. See
L<HTML::FormFu::Element/"CORE FORM FIELDS"> and
L<HTML::FormFu::Element/"OTHER CORE ELEMENTS">
for a list of core elements.

If you want to load an element from a namespace other than
C<HTML::FormFu::Element::>, you can use a fully qualified package-name by
prefixing it with C<+>.

    ---
    elements:
      - type: +MyApp::CustomElement
        name: foo

If a C<type> is not provided in the C<\%options>, the default C<Text> will
be used.

L</element> is an alias for L</elements>.

=head2 deflators

=head2 deflator

Arguments: $type

Arguments: \%options

Return Value: $deflator

Arguments: \@arrayref_of_types_or_options

Return Value: @deflators

A L<deflator|HTML::FormFu::Deflator> may be associated with any form field,
and allows you to provide
L<< $field->default|HTML::FormFu::Role::Element::Field/default >> with a value
which may be an object.

If an object doesn't stringify to a suitable value for display, the
L<deflator|HTML::FormFu::Deflator> can ensure that the form field
receives a suitable string value instead.

See L<HTML::FormFu::Deflator/"CORE DEFLATORS"> for a list of core deflators.

If a C<name> attribute isn't provided, a new deflator is created for and
added to every field on the form.

If you want to load a deflator in a namespace other than
C<HTML::FormFu::Deflator::>, you can use a fully qualified package-name by
prefixing it with C<+>.

L</deflator> is an alias for L</deflators>.

=head2 insert_before

Arguments: $new_element, $existing_element

Return Value: $new_element

The 1st argument must be the element you want added, the 2nd argument
must be the existing element that the new element should be placed before.

    my $new = $form->element(\%specs);

    my $position = $form->get_element({ type => $type, name => $name });

    $form->insert_before( $new, $position );

In the first line of the above example, the C<$new> element is initially
added to the end of the form. However, the C<insert_before> method
reparents the C<$new> element, so it will no longer be on the end of the
form. Because of this, if you try to copy an element from one form to
another, it will 'steal' the element, instead of copying it. In this case,
you must use C<clone>:

    my $new = $form1->get_element({ type => $type1, name => $name1 })
                    ->clone;

    my $position = $form2->get_element({ type => $type2, name => $name2 });

    $form2->insert_before( $new, $position );

=head2 insert_after

Arguments: $new_element, $existing_element

Return Value: $new_element

The 1st argument must be the element you want added, the 2nd argument
must be the existing element that the new element should be placed after.

    my $new = $form->element(\%specs);

    my $position = $form->get_element({ type => $type, name => $name });

    $form->insert_after( $new, $position );

In the first line of the above example, the C<$new> element is initially
added to the end of the form. However, the C<insert_after> method
reparents the C<$new> element, so it will no longer be on the end of the
form. Because of this, if you try to copy an element from one form to
another, it will 'steal' the element, instead of copying it. In this case,
you must use C<clone>:

    my $new = $form1->get_element({ type => $type1, name => $name1 })
                    ->clone;

    my $position = $form2->get_element({ type => $type2, name => $name2 });

    $form2->insert_after( $new, $position );

=head2 remove_element

Arguments: $element

Return Value: $element

Removes the C<$element> from the form or block's array of children.

    $form->remove_element( $element );

The orphaned element cannot be usefully used for anything until it is
re-attached to a form or block with L</insert_before> or L</insert_after>.

=head1 FORM LOGIC AND VALIDATION

L<HTML::FormFu|HTML::FormFu> provides several stages for what is
traditionally described as I<validation>. These are:

=over

=item L<HTML::FormFu::Filter|HTML::FormFu::Filter>

=item L<HTML::FormFu::Constraint|HTML::FormFu::Constraint>

=item L<HTML::FormFu::Inflator|HTML::FormFu::Inflator>

=item L<HTML::FormFu::Validator|HTML::FormFu::Validator>

=item L<HTML::FormFu::Transformer|HTML::FormFu::Transformer>

=back

The first stage, the filters, allow for cleanup of user-input, such as
encoding, or removing leading/trailing whitespace, or removing non-digit
characters from a creditcard number.

All of the following stages allow for more complex processing, and each of
them have a mechanism to allow exceptions to be thrown, to represent input
errors. In each stage, all form fields must be processed without error for
the next stage to proceed. If there were any errors, the form should be
re-displayed to the user, to allow them to input correct values.

Constraints are intended for low-level validation of values, such as
"is this an integer?", "is this value within bounds?" or
"is this a valid email address?".

Inflators are intended to allow a value to be turned into an appropriate
object. The resulting object will be passed to subsequent Validators and
Transformers, and will also be returned by L</params> and L</param>.

Validators are intended for higher-level validation, such as
business-logic and database constraints such as "is this username unique?".
Validators are only run if all Constraints and Inflators have run
without errors. It is expected that most Validators will be
application-specific, and so each will be implemented as a separate class
written by the HTML::FormFu user.

=head2 filters

=head2 filter

Arguments: $type

Arguments: \%options

Return Value: $filter

Arguments: \@arrayref_of_types_or_options

Return Value: @filters

If you provide a C<name> or C<names> value, the filter will be added to
just that named field.
If you do not provide a C<name> or C<names> value, the filter will be added
to all L<fields|HTML::FormFu::Role::Element::Field> already attached to the form.

See L<HTML::FormFu::Filter/"CORE FILTERS"> for a list of core filters.

If you want to load a filter in a namespace other than
C<HTML::FormFu::Filter::>, you can use a fully qualified package-name by
prefixing it with C<+>.

L</filter> is an alias for L</filters>.

=head2 constraints

=head2 constraint

Arguments: $type

Arguments: \%options

Return Value: $constraint

Arguments: \@arrayref_of_types_or_options

Return Value: @constraints

See L<HTML::FormFu::Constraint/"CORE CONSTRAINTS"> for a list of core
constraints.

If a C<name> attribute isn't provided, a new constraint is created for and
added to every field on the form.

If you want to load a constraint in a namespace other than
C<HTML::FormFu::Constraint::>, you can use a fully qualified package-name by
prefixing it with C<+>.

L</constraint> is an alias for L</constraints>.

=head2 inflators

=head2 inflator

Arguments: $type

Arguments: \%options

Return Value: $inflator

Arguments: \@arrayref_of_types_or_options

Return Value: @inflators

See L<HTML::FormFu::Inflator/"CORE INFLATORS"> for a list of core inflators.

If a C<name> attribute isn't provided, a new inflator is created for and
added to every field on the form.

If you want to load an inflator in a namespace other than
C<HTML::FormFu::Inflator::>, you can use a fully qualified package-name by
prefixing it with C<+>.

L</inflator> is an alias for L</inflators>.

=head2 validators

=head2 validator

Arguments: $type

Arguments: \%options

Return Value: $validator

Arguments: \@arrayref_of_types_or_options

Return Value: @validators

See L<HTML::FormFu::Validator/"CORE VALIDATORS"> for a list of core
validators.

If a C<name> attribute isn't provided, a new validator is created for and
added to every field on the form.

If you want to load a validator in a namespace other than
C<HTML::FormFu::Validator::>, you can use a fully qualified package-name by
prefixing it with C<+>.

L</validator> is an alias for L</validators>.

=head2 transformers

=head2 transformer

Arguments: $type

Arguments: \%options

Return Value: $transformer

Arguments: \@arrayref_of_types_or_options

Return Value: @transformers

See L<HTML::FormFu::Transformer/"CORE TRANSFORMERS"> for a list of core
transformers.

If a C<name> attribute isn't provided, a new transformer is created for and
added to every field on the form.

If you want to load a transformer in a namespace other than
C<HTML::FormFu::Transformer::>, you can use a fully qualified package-name by
prefixing it with C<+>.

L</transformer> is an alias for L</transformers>.

=head1 CHANGING DEFAULT BEHAVIOUR

=head2 render_processed_value

The default behaviour when re-displaying a form after a submission, is that
the field contains the original unchanged user-submitted value.

If L</render_processed_value> is true, the field value will be the final
result after all Filters, Inflators and Transformers have been run.
Deflators will also be run on the value.

If you set this on a field with an Inflator, but without an equivalent
Deflator, you should ensure that the Inflators stringify back to a usable
value, so as not to confuse / annoy the user.

Default Value: false

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

Is an L<inheriting accessor|/INHERITING ACCESSORS>.

=head2 force_errors

Force a constraint to fail, regardless of user input.

If this is called at runtime, after the form has already been processed,
you must called L<HTML::FormFu/process> again before redisplaying the
form to the user.

Default Value: false

This method is a special 'inherited accessor', which means it can be set on
the form, a block element, an element or a single constraint. When the value
is read, if no value is defined it automatically traverses the element's
hierarchy of parents, through any block elements and up to the form,
searching for a defined value.

Is an L<inheriting accessor|/INHERITING ACCESSORS>.

=head2 params_ignore_underscore

If true, causes L</params>, L</param> and L</valid> to ignore any fields
whose name starts with an underscore C<_>.

The field is still processed as normal, and errors will cause
L</submitted_and_valid> to return false.

Default Value: false

=head1 FORM ATTRIBUTES

All attributes are added to the rendered form's start tag.

=head2 attributes

    # Example
    ---
    attributes:
      id: form
      class: fancy_form

Is an L<attribute accessor|HTML::FormFu/ATTRIBUTE ACCESSOR>.

=head2 id

Is an L<attribute short-cut|HTML::FormFu/ATTRIBUTE SHORT-CUTS>.

=head2 action

Default Value: ""

Get or set the action associated with the form. The default is no action,
which causes most browsers to submit to the current URI.

Is an L<attribute short-cut|HTML::FormFu/ATTRIBUTE SHORT-CUTS>.

=head2 enctype

Get or set the encoding type of the form. Valid values are
C<application/x-www-form-urlencoded> and C<multipart/form-data>.

If the form contains a File element, the enctype is automatically set to
C<multipart/form-data>.

Is an L<attribute short-cut|HTML::FormFu/ATTRIBUTE SHORT-CUTS>.

=head2 method

Default Value: "post"

Get or set the method used to submit the form. Can be set to either "post"
or "get".

Is an L<attribute short-cut|HTML::FormFu/ATTRIBUTE SHORT-CUTS>.

=head2 title

Get or set the form's title attribute.

Is an L<attribute short-cut|HTML::FormFu/ATTRIBUTE SHORT-CUTS>.

=head1 CSS CLASSES

=head2 form_error_message_class

Class attribute for the error message displayed at the top of the form.

See L</"form_error_message">

=head1 LOCALIZATION

=head2 languages

Arguments: [\@languages]

A list of languages which will be passed to the localization object.

Default Value: ['en']

=head2 localize_class

Arguments: [$class_name]

Classname to be used for the default localization object.

Default Value: 'HTML::FormFu::I18N'

=head2 localize

=head2 loc

Arguments: [$key, @arguments]

Compatible with the C<maketext> method in L<Locale::Maketext>.

=head2 locale

Arguments: $locale

Currently only used by L<HTML::FormFu::Deflator::FormatNumber> and
L<HTML::FormFu::Filter::FormatNumber>.

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

Is an L<inheriting accessor|/INHERITING ACCESSORS>.

=head1 PROCESSING A FORM

=head2 query

Arguments: [$query_object]

Arguments: \%params

Provide a L<CGI> compatible query object or a hash-ref of submitted
names/values. Alternatively, the query object can be passed directly to the
L</process> object.

=head2 query_type

Arguments: [$query_type]

Set which module is being used to provide the L</query>.

The L<Catalyst::Controller::HTML::FormFu> automatically sets this to
C<Catalyst>.

Valid values are C<CGI>, C<Catalyst> and C<CGI::Simple>.

Default Value: 'CGI'

=head2 process

Arguments: [$query_object]

Arguments: [\%params]

Process the provided query object or input values. C<process> must be called
before calling any of the methods listed under
L</"SUBMITTED FORM VALUES AND ERRORS"> and L</"MODIFYING A SUBMITTED FORM">.

C<process> must also be called at least once before printing the form or
calling L</render> or L</render_data>.

Note to users of L<Catalyst::Controller::HTML::FormFu>: Because L</process>
is automatically called for you by the Catalyst controller; if you make any
modifications to the form within your action method, such as adding or changing
elements, adding constraints, etc; you must call L</process> again yourself
before using L</submitted_and_valid>, any of the methods listed under
L</"SUBMITTED FORM VALUES AND ERRORS"> or
L</"MODIFYING A SUBMITTED FORM">, or rendering the form.

=head1 SUBMITTED FORM VALUES AND ERRORS

=head2 submitted

Returns true if the form has been submitted. See L</indicator> for details
on how this is computed.

=head2 submitted_and_valid

Shorthand for C<< $form->submitted && !$form->has_errors >>

=head2 params

Return Value: \%params

Returns a hash-ref of all valid input for which there were no errors.

=head2 param_value

Arguments: $field_name

A more reliable, recommended version of L</param>. Guaranteed to always return a
single value, regardless of whether it's called in list context or not. If
multiple values were submitted, this only returns the first value. If the value
is invalid or the form was not submitted, it returns C<undef>. This makes it
suitable for use in list context, where a single value is required.

    $db->update({
        name    => $form->param_value('name'),
        address => $form->param_value('address),
    });

=head2 param_array

Arguments: $field_name

Guaranteed to always return an array-ref of values, regardless of context and
regardless of whether multiple values were submitted or not. If the value is
invalid or the form was not submitted, it returns an empty array-ref.

=head2 param_list

Arguments: $field_name

Guaranteed to always return a list of values, regardless of context. If the value is
invalid or the form was not submitted, it returns an empty list.

=head2 param

Arguments: [$field_name]

Return Value: $input_value

Return Value: @valid_names

No longer recommended for use, as its behaviour is hard to predict. Use
L</param_value>, L</param_array> or L</param_list> instead.

A (readonly) method similar to that of L<CGI's|CGI>.

If a field name is given, in list-context returns any valid values submitted
for that field, and in scalar-context returns only the first of any valid
values submitted for that field.

If no argument is given, returns a list of all valid input field names
without errors.

Passing more than 1 argument is a fatal error.

=head2 valid

Arguments: [$field_name]

Return Value: @valid_names

Return Value: $bool

If a field name if given, returns C<true> if that field had no errors and
C<false> if there were errors.

If no argument is given, returns a list of all valid input field names
without errors.

=head2 has_errors

Arguments: [$field_name]

Return Value: @names

Return Value: $bool

If a field name if given, returns C<true> if that field had errors and
C<false> if there were no errors.

If no argument is given, returns a list of all input field names with errors.

=head2 get_errors

Arguments: [%options]

Arguments: [\%options]

Return Value: \@errors

Returns an array-ref of exception objects from all fields in the form.

Accepts both C<name>, C<type> and C<stage> arguments to narrow the returned
results.

    $form->get_errors({
        name  => 'foo',
        type  => 'Regex',
        stage => 'constraint'
    });

=head2 get_error

Arguments: [%options]

Arguments: [\%options]

Return Value: $error

Accepts the same arguments as L</get_errors>, but only returns the first
error found.

=head1 MODEL / DATABASE INTERACTION

See L<HTML::FormFu::Model> for further details and available models.

=head2 default_model

Arguments: $model_name

Default Value: 'DBIC'

=head2 model

Arguments: [$model_name]

Return Value: $model

=head2 model_config

Arguments: \%config

=head1 MODIFYING A SUBMITTED FORM

=head2 add_valid

Arguments: $name, $value

Return Value: $value

The provided value replaces any current value for the named field. This
value will be returned in subsequent calls to L</params> and L</param> and
the named field will be included in calculations for L</valid>.

=head2 clear_errors

Deletes all errors from a submitted form.

=head1 RENDERING A FORM

=head2 render

Return Value: $string

You must call L</process> once after building the form, and before calling
L</render>.

=head2 start

Return Value: $string

Returns the form start tag, and any output of L</form_error_message> and
L</javascript>.

=head2 end

Return Value: $string

Returns the form end tag.

=head2 hidden_fields

Return Value: $string

Returns all hidden form fields.

=head1 PLUGIN SYSTEM

C<HTML::FormFu> provides a plugin-system that allows plugins to be easily
added to a form or element, to change the default behaviour or output.

See L<HTML::FormFu::Plugin> for details.

=head1 ADVANCED CUSTOMISATION

By default, formfu renders "XHTML 1.0 Strict" compliant markup, with as
little extra markup as possible. Many hooks are provided to add
programmatically-generated CSS class names, to allow for a wide-range of
output styles to be generated by changing only the CSS.

Basic customisation of the markup is possible via the
L<layout|HTML::FormFu::Role::Element::Field/layout> and
L<multi_layout|HTML::FormFu::Role::Element::Field/multi_layout> methods.
This allows you to reorder the position of various parts of each field -
such as the label, comment, error messages and the input tag - as well
as inserting any other arbitrary tags you may wish.

If this is not sufficient, you can make completely personalise the markup
by telling HTML::FormFu to use an external rendering engine, such as
L<Template Toolkit|Template> or L<Template::Alloy>.
See L</render_method> and L</tt_module> for details.

Even if you set HTML::FormFu to use L<Template::Toolkit|Template> to render,
the forms, HTML::FormFu can still be used in conjunction with whichever other
templating system you prefer to use for your own page layouts, whether it's
L<HTML::Template>: C<< <TMPL_VAR form> >>,
L<Petal>: C<< <form tal:replace="form"></form> >>
or L<Template::Magic>: C<< <!-- {form} --> >>.

As of C<HTML::FormFu v1.00>, L<TT|Template> is no longer listed a required
prerequisite - so you'll need to install it manually if you wish to use the
template files.

=head2 render_method

Default Value: C<string>

Can be set to C<tt> to generate the form with external template files.

To customise the markup, you'll need a copy of the template files, local to
your application. See
L<HTML::FormFu::Manual::Cookbook/"Installing the TT templates"> for further
details.

You can customise the markup for a single element by setting that element's
L</render_method> to C<tt>, while the rest of the form uses the default
C<string> render-method. Note though, that if you try setting the form or a
Block's L</render_method> to C<tt>, and then set a child element's
L</render_method> to C<string>, that setting will be ignored, and the child
elements will still use the C<tt> render-method.

    ---
    elements:
      - name: foo
        render_method: tt
        filename: custom_field

      - name: bar

    # in this example, 'foo' will use a custom template,
    # while bar will use the default 'string' rendering method

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

Is an L<inheriting accessor|/INHERITING ACCESSORS>.

=head2 filename

Change the template filename used for the form.

Default Value: "form"

=head2 tt_args

Arguments: [\%constructor_arguments]

Accepts a hash-ref of arguments passed to L</render_method>, which is called
internally by L</render>.

Within tt_args, the keys C<RELATIVE> and C<RECURSION> are overridden to always
be true, as these are a basic requirement for the L<Template> engine.

The system directory containing HTML::FormFu's template files is always
added to the end of C<INCLUDE_PATH>, so that the core template files will be
found. You only need to set this yourself if you have your own copy of the
template files for customisation purposes.

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

=head2 add_tt_args

Arguments: [\%constructor_arguments]

Ensures that the hash-ref argument is merged with any existing hash-ref
value of L</tt_args>.

=head2 tt_module

Default Value: Template

The module used when L</render_method> is set to C<tt>. Should provide an
interface compatible with L<Template>.

This method is a special 'inherited accessor', which means it can be set on
the form, a block element or a single element. When the value is read, if
no value is defined it automatically traverses the element's hierarchy of
parents, through any block elements and up to the form, searching for a
defined value.

=head2 render_data

Usually called implicitly by L</render>. Returns the data structure that
would normally be passed onto the C<string> or C<tt> render-methods.

As with L</render>, you must call L</process> once after building the form,
and before calling L</render_data>.


=head2 render_data_non_recursive

Like L</render_data>, but doesn't include the data for any child-elements.

=head1 INTROSPECTION

=head2 get_fields

Arguments: [%options]

Arguments: [\%options]

Return Value: \@elements

Returns all fields in the form (specifically, all elements which have a true
L<HTML::FormFu::Element/is_field> value).

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_fields({
        name => 'foo',
        type => 'Radio',
    });

Accepts also an Regexp to search for results.

    $form->get_elements({
        name => qr/oo/,
    });

=head2 get_field

Arguments: [%options]

Arguments: [\%options]

Return Value: $element

Accepts the same arguments as L</get_fields>, but only returns the first
field found.

=head2 get_elements

Arguments: [%options]

Arguments: [\%options]

Return Value: \@elements

Returns all top-level elements in the form (not recursive).
See L</get_all_elements> for a recursive version.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_elements({
        name => 'foo',
        type => 'Radio',
    });

Accepts also an Regexp to search for results.

    $form->get_elements({
        name => qr/oo/,
    });

=head2 get_element

Arguments: [%options]

Arguments: [\%options]

Return Value: $element

Accepts the same arguments as L</get_elements>, but only returns the first
element found.

See L</get_all_element> for a recursive version.

=head2 get_all_elements

Arguments: [%options]

Arguments: [\%options]

Return Value: \@elements

Returns all elements in the form recursively.

Optionally accepts both C<name> and C<type> arguments to narrow the returned
results.

    # return all Text elements

    $form->get_all_elements({
        type => 'Text',
    });

Accepts also an Regexp to search for results.

    $form->get_elements({
        name => qr/oo/,
    });

See L</get_elements> for a non-recursive version.

=head2 get_all_element

Arguments: [%options]

Arguments: [\%options]

Return Value: $element

Accepts the same arguments as L</get_all_elements>, but only returns the
first element found.

    # return the first Text field found, regardless of whether it's
    # within a fieldset or not

    $form->get_all_element({
        type => 'Text',
    });

Accepts also an Regexp to search for results.

    $form->get_elements({
        name => qr/oo/,
    });

See L</get_all_elements> for a non-recursive version.

=head2 get_deflators

Arguments: [%options]

Arguments: [\%options]

Return Value: \@deflators

Returns all top-level deflators from all fields.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_deflators({
        name => 'foo',
        type => 'Strftime',
    });

=head2 get_deflator

Arguments: [%options]

Arguments: [\%options]

Return Value: $element

Accepts the same arguments as L</get_deflators>, but only returns the first
deflator found.

=head2 get_filters

Arguments: [%options]

Arguments: [\%options]

Return Value: \@filters

Returns all top-level filters from all fields.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_filters({
        name => 'foo',
        type => 'LowerCase',
    });

=head2 get_filter

Arguments: [%options]

Arguments: [\%options]

Return Value: $filter

Accepts the same arguments as L</get_filters>, but only returns the first
filter found.

=head2 get_constraints

Arguments: [%options]

Arguments: [\%options]

Return Value: \@constraints

Returns all constraints from all fields.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_constraints({
        name => 'foo',
        type => 'Equal',
    });

=head2 get_constraint

Arguments: [%options]

Arguments: [\%options]

Return Value: $constraint

Accepts the same arguments as L</get_constraints>, but only returns the
first constraint found.

=head2 get_inflators

Arguments: [%options]

Arguments: [\%options]

Return Value: \@inflators

Returns all inflators from all fields.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_inflators({
        name => 'foo',
        type => 'DateTime',
    });

=head2 get_inflator

Arguments: [%options]

Arguments: [\%options]

Return Value: $inflator

Accepts the same arguments as L</get_inflators>, but only returns the
first inflator found.

=head2 get_validators

Arguments: [%options]

Arguments: [\%options]

Return Value: \@validators

Returns all validators from all fields.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_validators({
        name => 'foo',
        type => 'Callback',
    });

=head2 get_validator

Arguments: [%options]

Arguments: [\%options]

Return Value: $validator

Accepts the same arguments as L</get_validators>, but only returns the
first validator found.

=head2 get_transformers

Arguments: [%options]

Arguments: [\%options]

Return Value: \@transformers

Returns all transformers from all fields.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_transformers({
        name => 'foo',
        type => 'Callback',
    });

=head2 get_transformer

Arguments: [%options]

Arguments: [\%options]

Return Value: $transformer

Accepts the same arguments as L</get_transformers>, but only returns the
first transformer found.

=head2 clone

Returns a deep clone of the C<$form> object.

Because of scoping issues, code references (such as in Callback constraints)
are copied instead of cloned.

=head1 ATTRIBUTE ACCESSORS

For the basic method, e.g. C</attributes>:

Arguments: [%attributes]

Arguments: [\%attributes]

Return Value: $form

As a special case, if no arguments are passed, the attributes hash-ref is
returned. This allows the following idioms.

    # set a value
    $form->attributes->{id} = 'form';

    # delete all attributes
    %{ $form->attributes } = ();

All methods documented as 'attribute accessors' also have the following
variants generated:

C<*_xml> can be used as a setter, and ensures that its argument is not
XML-escaped in the rendered form.

C<*_loc> can he used as a setter, and passes the arguments through
L</localize>.

C<add_*> can be used to append a word to an attribute without overwriting
any already-existing value.

    # Example
    $form->attributes({ class => 'fancy' });
    $form->add_attributes({ class => 'pants' });
    # class="fancy pants"

C<add_*_xml>, like C<add_*>, but ensures it doesn't get XML-escaped.

C<add_*_loc>, like C<add_*>, but passing the arguments through L</localize>.

C<del_*> can be used to remove a word from an attribute value.

    # Example
    $form->attributes({ class => 'fancy pants' });
    $form->del_attributes({ class => 'pants' });
    # class="fancy"

C<del_*_xml>, like C<del_*>, but ensures it doesn't get XML-escaped.

C<del_*_loc>, like C<del_*>, but passing the arguments through L</localize>.

Also, any attribute method-name which contains the word C<attributes> also
has aliases created for all these variants, with the word C<attributes>
replaced by C<attrs>.

    # For example, the attributes() method would have all these variant
    # methods available

    $form->attributes({ class => 'fancy' });
    $form->attributes_xml({ title => '<b>fancy</b>' });
    $form->attributes_loc({ title => 'fancy' });
    $form->add_attributes({ class => 'fancy' });
    $form->add_attributes_xml({ title => '<b>fancy</b>' });
    $form->add_attributes_loc({ title => 'fancy' });
    $form->del_attributes({ class => 'fancy' });
    $form->del_attributes_xml({ title => '<b>fancy</b>' });
    $form->del_attributes_loc({ title => 'fancy' });

    # Because the method contains the word 'attributes', it also gets the
    # following short-forms

    $form->attrs({ class => 'fancy' });
    $form->attrs_xml({ title => '<b>fancy</b>' });
    $form->attrs_loc({ title => 'fancy' });
    $form->add_attrs({ class => 'fancy' });
    $form->add_attrs_xml({ title => '<b>fancy</b>' });
    $form->add_attrs_loc({ title => 'fancy' });
    $form->del_attrs({ class => 'fancy' });
    $form->del_attrs_xml({ title => '<b>fancy</b>' });
    $form->del_attrs_loc({ title => 'fancy' });

=head1 ATTRIBUTE SHORT-CUTS

All methods documented as 'attribute short-cuts' are short-cuts to directly
access individual attribute key/values.

    # Example
    $form->id( 'login' );
    $id = $form->id;

    # is equivalent to:
    $form->attributes({ id => 'login' });
    $id = $form->attributes->{id};

All attribute short-cuts also have a C<*_xml> variant.

    # Example
    $form->id_xml( $xml );

    # is equivalent to:
    $form->attributes_xml({ id => $xml });

All attribute short-cuts also have a C<*_loc> variant.

    # Example
    $form->title_loc( $key );

    # is equivalent to:
    $form->attributes_loc({ title => $key });

=head1 INHERITING ACCESSORS

All methods documented as 'inheriting accessors' can be set on the form,
a block element or a single field element.
When the value is read, if no value is defined it automatically traverses
the element's hierarchy of parents, searching for a defined value.

All inherited accessors also have a C<*_no_inherit> variant, which can be
used as a getter to fetch any defined value, without traversing the
hierarchy of parents. This variant cannot be used as a setter.

E.g., the L</auto_id> has a variant named C<auto_id_no_inherit>.

=head1 OUTPUT ACCESSORS

All methods documented as 'output accessors' also have C<*_xml> and C<*_loc>
variants.

The C<*_xml> variant can be used as a setter, and ensures that its
argument is not XML-escaped in the rendered form.

The C<*_loc> variant can be used as a setter, and passes the arguments
through L</localize>.

E.g., the L<label|HTML::FormFu::Role::Element::Field/label> method has
variants named C<label_xml> and C<label_loc>.

=head1 BOOLEAN ATTRIBUTE ACCESSORS

To support boolean attributes, whose value should either be equal to the
attribute name, or empty. Any true value will switch the attribute 'on', any
false value will remove the attribute.

    # Example

    $field->autofocus(1);
    # equivalent to:
    $field->attributes({ autofocus => 'autofocus' });

    $field->autofocus(0);;
    # equivalent to:
    delete $field->attributes->{autofocus};

=head1 ATTRIBUTE SUBSTITUTIONS

Some attributes support character substitutions: the following substitutions
are possible:

    %f # $form->id
    %n # $field->name
    %t # lc( $field->type )
    %r # $block->repeatable_count
    %s # $error->stage

These allow each field to have consistent attributes, while remaining unique.

=head1 DEPRECATION POLICY

We try our best to not make incompatible changes, but if they're required
we'll make every effort possible to provide backwards compatibility for
several release-cycles, issuing a warnings about the changes, before removing
the legacy features.

=head1 RESTORING LEGACY HTML CLASSES

C<v1.00> dropped most of the default HTML class-names, with the intention
that each application should define just what it needs, without needing to
reset unwanted options first. We also gain the benefit of less markup being
generated, speeding up both L<render|/render> and HTTP transfers.

To restore the previous behaviour, set the following options.

If you're using L<best practices|/"BEST PRACTICES">, you'll only need to set
these once per-application in your app-wide config file.

    ---
    auto_container_class: '%t'
    auto_container_label_class: 'label'
    auto_container_comment_class: 'comment'
    auto_comment_class: 'comment'
    auto_container_error_class: 'error'
    auto_container_per_error_class: 'error_%s_%t'
    auto_error_class: 'error_message error_%s_%t'

=head1 DEPRECATED METHODS

See L<HTML::FormFu::Role::Element::Field/"DEPRECATED METHODS">.

=head1 REMOVED METHODS

See also L<HTML::FormFu::Element/"REMOVED METHODS">.

=head2 element_defaults

Has been removed; see L</default_args> instead.

=head2 model_class

Has been removed; use L</default_model> instead.

=head2 defaults_from_model

Has been removed; use L<HTML::FormFu::Model/default_values> instead.

=head2 save_to_model

Has been removed; use L<HTML::FormFu::Model/update> instead.

=head1 BEST PRACTICES

It is advisable to keep application-wide (or global) settings in a single
config file, which should be loaded by each form.

See L</load_config_file>.

=head1 COOKBOOK

L<HTML::FormFu::Manual::Cookbook>

=head2 UNICODE

L<HTML::FormFu::Manual::Unicode>

=head1 EXAMPLES

=head2 vertically-aligned CSS

The distribution directory C<examples/vertically-aligned> contains a form with
example CSS for a "vertically aligned" theme.

This can be viewed by opening the file C<vertically-aligned.html> in a
web-browser.

If you wish to experiment with making changes, the form is defined in file
C<vertically-aligned.yml>, and the HTML file can be updated with any changes
by running the following command (while in the distribution root directory).

    perl examples/vertically-aligned/vertically-aligned.pl

This uses the L<Template Toolkit|Template> file C<vertically-aligned.tt>,
and the CSS is defined in files C<vertically-aligned.css> and
C<vertically-aligned-ie.css>.

=head1 SEE ALSO

L<HTML::FormFu::Imager>

L<Catalyst::Controller::HTML::FormFu>

L<HTML::FormFu::Model::DBIC>

=head1 CONTRIBUTORS

Brian Cassidy

Ozum Eldogan

Ruben Fonseca

Ronald Kimball

Daisuke Maki

Andreas Marienborg

Mario Minati

Steve Nolte

Moritz Onken

Doug Orleans

Matthias Dietrich

Dean Hamstead

Karen Etheridge

Nigel Metheringham

Based on the original source code of L<HTML::Widget>, by Sebastian Riedel,
C<sri@oook.de>.

=cut
