package TableEdit::CRUD;

use Dancer ':syntax';
use Dancer::Plugin::Form;

use Array::Utils qw(:all);
use Digest::SHA qw(sha256_hex);
use Dancer::Plugin::Ajax;

use Pager;
use Params;

use Dancer::Plugin::DBIC qw(schema resultset rset);
use DBIx::Class::ResultClass::HashRefInflator;

my $layout = {};
my $as_hash = 'DBIx::Class::ResultClass::HashRefInflator';
my $dropdown_treshold = 100;
my $page_size = 10;


get '/api/:class/list' => sub {
	my $class = params->{class};
	my $get_params = params('query');
	my $post_params = params('body');
	my $grid_params;		
	# Grid
	$grid_params = grid_template_params($class, $post_params, $get_params);
	
	$grid_params->{'grid_url'} = "/grid/$class";
	$grid_params->{default_actions} = 1;
	$grid_params->{'grid_title'} = ucfirst($class)."s";
	
	content_type 'application/json';
	#$grid_params->{field_list}->[8] = undef;
	return to_json $grid_params;
};


get '/api/menu' => sub {
	content_type 'application/json';
	return to_json [map {name=> class_label($_), url=>"#/$_/list"}, @{classes()}];;
};


sub classes {
	my $classes = [sort values schema->{class_mappings}];
	my $classes_with_pk = [];
	for my $class (@$classes){
		my @pk = schema->source($class)->primary_columns;
		push $classes_with_pk, $class if (@pk == 1);
	}
	return $classes_with_pk;
}


sub class_label {
	my $class = shift;
	$class =~ s/(?<! )([A-Z])/ $1/g; # Search for "(?<!pattern)" in perldoc perlre 
	$class =~ s/^ (?=[A-Z])//; # Strip out extra starting whitespace followed by A-Z
	return $class;
}


sub all_columns {
	my $class = shift;		
	return [schema->resultset(ucfirst($class))->result_source->columns]; 
}


sub grid_columns_info {
	my ($class, $sort) = @_;
	my $defuault_columns = [];
	my ($columns, $relationships) = columns_and_relationships_info(
		$class, 
		schema->resultset(ucfirst($class))->result_source->resultset_attributes->{grid_columns}
	);
	for my $col (@$columns){
		unless (
			($col->{data_type} and $col->{data_type} eq 'text') or
			($col->{size} and $col->{size} > 255)
		){
			$col->{class} = 'selected' if $sort and ($sort eq $_ or $sort eq "$_ desc");
			push $defuault_columns, $col 
		};
	}
	return $defuault_columns; 
}


sub columns_and_relationships_info {
	my ($class, $simple_columns) = @_;
	my $result_source = schema->resultset(ucfirst($class))->result_source;
	my $columns = $result_source->columns_info; 
	my $relationships = [$result_source->relationships];
	my $many_to_manys = $result_source->resultset_attributes->{many_to_many};
	$simple_columns ||= all_columns($class);
	my $columns_info = [];
	my $relationships_info = [];
	
	for my $many_to_many (keys %$many_to_manys){
		my ($relationship_info);
		$relationship_info->{foreign} = $many_to_many;
		$relationship_info->{foreign_type} = 'has_many';
		column_add_info($many_to_many, $relationship_info );
		push $relationships_info, $relationship_info;
	}
	
	for my $relationship(@$relationships){
		my $column_name;
		my $relationship_info = $result_source->relationship_info($relationship);
		my $relationship_class_name = $relationship_info->{class};
		#next unless grep $_ eq $relationship, @$simple_columns;
		next if $relationship_info->{hidden};
		my $relationship_class = schema->class_mappings->{$relationship_class_name};
		my $count = schema->resultset($relationship_class)->count;
		
		for (values $relationship_info->{cond}){
			$column_name ||= [split('\.', "$_")]->[-1];
			last;
		}
		my $column_info = $columns->{$column_name};
		$relationship_info->{foreign} = $relationship;

		my $rel_type = $relationship_info->{attrs}->{accessor};
		# Belongs to
		if( $rel_type eq 'single' or $rel_type eq 'filter' ){
			$relationship_info->{foreign_type} = 'belongs_to';
			if ($count <= $dropdown_treshold){
				$relationship_info->{field_type} = 'dropdown';
				
				my @foreign_objects = schema->resultset($relationship_class)->all;
				$relationship_info->{options} = dropdown(\@foreign_objects);
			}
			else {
				$relationship_info->{field_type} = 'text_field';
			} 
			column_add_info($column_name, $relationship_info );
			push $columns_info, $relationship_info;
		}
		
		# Has many
		elsif( $rel_type eq 'multi' ){
			# Only tables with one PK
			my @pk = schema->source($relationship_class)->primary_columns;
			next unless scalar @pk == 1;
			
			$relationship_info->{foreign_type} = 'has_many';
			
			column_add_info($column_name, $relationship_info );
			push $relationships_info, $relationship_info;
		}
		
	}
	
	for (@$simple_columns){
		my $column_info = $columns->{$_};
		next if $column_info->{is_foreign_key} or $column_info->{hidden};
		column_add_info($_, $column_info);
		
		push $columns_info, $column_info;
	} 
	
	return ($columns_info, $relationships_info);
}


sub column_add_info {
	my ($column_name, $column_info) = @_;
	return undef if $column_info->{hidden};
	$column_info->{field_type} ||= field_type($column_info);
	$column_info->{default_value} = ${$column_info->{default_value}} if ref($column_info->{default_value}) eq 'SCALAR' ;
	$column_info->{original} = undef;
	$column_info->{name} ||= $column_name; # Column database name
	$column_info->{label} ||= label($column_name); #Human label
	$column_info->{$column_info->{field_type}} = 1; # For Flute containers
	$column_info->{required} ||= 'required' if defined $column_info->{is_nullable} and $column_info->{is_nullable} == 0;
	
	# Remove size info if select
	delete $column_info->{size} if $column_info->{field_type} eq 'dropdown';
			
	# Remove not null if checkbox			
	delete $column_info->{is_nullable} if $column_info->{field_type} eq 'checkbox';
			
	return undef if index($column_info->{field_type}, 'timestamp') != -1;
	
}


sub add_values {
	my ($columns_info, $values) = @_;
	
	for my $column_info (@$columns_info){
		my $value = $values->{$column_info->{name}};
		if( $column_info->{options} ){
			next unless $value;
			for my $option (@{ $column_info->{options} }){
				next unless $option->{value};
				if ($option->{value} == $value or $option->{value} eq $value){
					$option->{selected} = 'selected';
				}
			}
		}
		else {
			$column_info->{value} = $value;
		}
	}
	
}


sub field_type {
	my $field = shift;
	my $data_type = $field->{data_type};
	my $field_type = {
		boolean => 'checkbox',
		text => 'text_area',
	}; 
	return (($data_type and $field_type->{$data_type}) ? $field_type->{$data_type} : 'text_field');
}


sub label {
	my $field = shift;
	$field =~ s/_/ /g;	
	return ucfirst($field);
}


sub dropdown {
	my ($result_set, $selected) = @_;
	my $items = [{option_label=>''}];
	for my $object (@$result_set){
		my $id_column = $object->result_source->_primaries->[0];
		my $id = $object->$id_column;
		my $name = "$object";
		push $items, {option_label=>$name, value=>$id};
	}
	return $items;
}


sub clean_values {
	my $values = shift;
	for my $key (keys %$values){
		$values->{$key} = undef if $values->{$key} eq '';
	}
	
}


sub related_search_actions {
	my $id = shift;
	return [
		{name => 'Add', link => "add/$id"}, 
	]
}


sub related_actions {
	my $id = shift;
	return [
		{name => 'Remove', link => "remove/$id"}
	]
}


sub grid_actions {
	my $id = shift;
	return [
		{name => '', link => "edit/$id", css=> 'icon-pencil btn-warning'}, 
		{name => '', link => "delete/$id", css=> 'icon-remove btn-danger'}
	];
}


sub grid_template_params {
	my ($class, $post_params, $get_params, $actions) = @_;
	my $template_params;
	my $where ||= {};	
	# Grid
	$template_params->{field_list} = grid_columns_info($class, $get_params->{sort});
	grid_where($template_params->{field_list}, $where, $post_params);
	add_values($template_params->{field_list}, $post_params);
	
	my $rs = schema->resultset(ucfirst($class));
	my ($primary_column) = schema->source(ucfirst($class))->primary_columns;
	my $page = $get_params->{page} || 1;
	my $sort = $get_params->{sort};
	
	my $objects = $rs->search(
	$where,
	  {
	    page => $page,  # page to return (defaults to 1)
	    rows => $page_size, # number of results per page
	    order_by => $sort,
	  },);
	my $count = $rs->search($where)->count;
	  
	unless ( $count ) {
		session error => 'Sorry, no results matching your filter(s). Try altering your filters.';
	}
	
	$template_params->{rows} = grid_rows(
		[$objects->all], 
		$template_params->{field_list} , 
		$primary_column, 
		$actions || \&grid_actions,		
	);
	
	$template_params->{class} = $class;
	
	# Pager
	my $pager = new Pager(pageSize => $page_size, url => "/grid/$class",);
	$template_params->{pagination} = $pager->getHtml($page, $count, {url_params => $get_params});
	return $template_params;
}


sub grid_related_template_params {
	my ($class, $related_items, $post_params, $get_params, $actions) = @_;
	my $template_params;
	my $where ||= {};	
	# Grid
	my $columns_info = grid_columns_info($class, $get_params->{sort});
	grid_where($columns_info, $where, $post_params, $related_items->{attrs}->{alias});
	add_values($columns_info, $post_params);
	
	my ($primary_column) = schema->source(ucfirst($class))->primary_columns;
	$get_params->{page} ||= 0;
	
	my $objects = $related_items->search(	
	$where,
	  {
	    page => $get_params->{page},  # page to return (defaults to 1)
	    rows => $page_size, # number of results per page
	    order_by => $get_params->{sort},
	  }
	  ,);
	my $count = $related_items->search($where)->count;
	  
	unless ( $count ) {
		session error => 'Sorry, no results matching your filter(s). Try altering your filters.';
	}
	
	$template_params->{rows} = grid_rows(
		[$objects->all], 
		$columns_info, 
		$primary_column, 
		$actions || \&grid_actions,		
	);
	
	$template_params->{class} = $class;
	
	# Pager
	my $pager = new Pager(pageSize => $page_size, url => "/grid/$class",);
	$template_params->{pagination} = $pager->getHtml($get_params->{page}, $count, {url_params => $get_params});
	$template_params->{field_list} = $columns_info;
	return $template_params;
}


sub grid_where {
	my ($columns, $where, $params, $alias) = @_;
	$alias ||= 'me';
	for my $field (@$columns) {
		# Search
		my $name = $field->{name};
		if( $params->{$name} ){
			if ($field->{data_type} and ($field->{data_type} eq 'text' or $field->{data_type} eq 'varchar')){
				$where->{"LOWER($alias.$name)"} = {'LIKE' => "%".lc($params->{$name})."%"};
			}
			else { #($field->{data_type} eq 'integer' or $field->{data_type} eq 'double')
				$where->{"$alias.$name"} = $params->{$name};	
			}
		}
	};
	
}


sub grid_rows {
	my ($rows, $columns_info, $primary_column, $actions_function, $args) = @_;
	
	my @table_rows; 
	for my $row (@$rows){
		die 'No primary column' unless $primary_column;
		my $id = $row->$primary_column;
		my $row_data = [];
		for my $column (@$columns_info){
			my $column_name = $column->{foreign} ? "$column->{foreign}" : "$column->{name}";
			my $value = $row->$column_name;
			$value = "$value" if $value;
			push $row_data, {value => $value};
		}
		my $actions = $actions_function ? $actions_function->($id) : undef;
		push @table_rows, {row => $row_data, id => $id, actions => $actions };
	}
	return \@table_rows;
}

true;