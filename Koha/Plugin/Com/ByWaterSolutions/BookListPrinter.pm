package Koha::Plugin::Com::ByWaterSolutions::BookListPrinter;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Items;

use Array::Utils qw(:all);
use Cwd          qw(abs_path);
use Data::Dumper;
use File::Temp qw(tempfile tempdir);
use JSON       qw(to_json);
use Try::Tiny;
use YAML qw(DumpFile LoadFile);
use C4::Letters;


our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Book List Printer',
    author          => 'Kyle M Hall',
    date_authored   => '2023-02-23',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Generate pages of books for printing and distribution.',
};

sub new {
    my ($class, $args) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            subject_depth => $self->retrieve_data('subject_depth'),
            title_format => $self->retrieve_data('title_format') || '[% biblio.title | html %]',
            author_format => $self->retrieve_data('author_format') || '[% biblio.author | html %]',
            item_format => $self->retrieve_data('item_format') || '[% item.itemcallnumber | html %]',
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                subject_depth => $cgi->param('subject_depth'),
                title_format => scalar $cgi->param('title_format'),
                author_format => scalar $cgi->param('author_format'),
                item_format => scalar $cgi->param('item_format'),


            }
        );
        $self->go_home();
    }
}

sub report {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    if ($cgi->param('output')) {
        $self->report_step2();
    } elsif ($cgi->param('download')) {
        $self->report_download();
    } elsif ($cgi->param('status')) {
        $self->report_status();
    } else {
        $self->report_step1();
    }
}

sub report_step1 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({file => 'report-step1.tt'});

    $template->param(wkhtmltopdf_installed => is_cmd_installed('wkhtmltopdf'));

    $self->output_html($template->output());
}

sub report_step2 {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    #my $logger = Koha::Logger->get({ interface => 'intranet'}, 1);
    #$logger->warn("TEST");

    my $display_by = $cgi->param('display_by');

    my @locations  = $cgi->multi_param('location');
    my @itemtypes  = $cgi->multi_param('itemtype');
    my @ccodes     = $cgi->multi_param('ccodes');
    my $branchcode = $cgi->param('branchcode');

    my ($afh, $html_file)   = tempfile(undef, SUFFIX => '.html');
    my ($sfh, $status_file) = tempfile(undef, SUFFIX => '.yml');
    warn "HTML: $html_file";
    warn "STATUS: $status_file";

    my $pid = fork;

    # Parent outputs status page and exits
    if ($pid != 0) {
        my $template = $self->get_template({file => 'report-step2-status.tt'});
        $template->param(status_file => $status_file);
        $self->output_html($template->output());
        exit;
    }

    # Child gets to work
    my $status = {
        pid       => $$,
        status    => 'Gathering data',
        pid       => $pid,
        html_file => $html_file,
        updated   => dt_from_string()->iso8601,
    };
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    my $template = $self->get_template({file => 'report-step2-html.tt'});

    my $items;
    my $title_format_template = $self->retrieve_data('title_format') || '[% biblio.title | html %]';
    my $author_format_template = $self->retrieve_data('author_format') || '[% biblio.author | html %]';
    my $item_format_template = $self->retrieve_data('item_format') || '[% item.itemcallnumber | html %]';

    if ($display_by =~ /^subject/) {
        my $tag = ( $display_by eq 'subject650' ) ? '650' : '655';


        my @parameters;

        my $query = q{
                SELECT plugin_book_list_printer_subjects.*
                FROM plugin_book_list_printer_subjects
                LEFT JOIN biblio USING ( biblionumber )
                LEFT JOIN biblioitems USING ( biblionumber )
                LEFT JOIN items USING ( biblionumber )
                WHERE tag = ?
            };
        push(@parameters, $tag);

        if (@itemtypes) {
            my $in_string = join(',', map {"\"$_\""} @itemtypes);
            $query .= qq{
                AND (
                    biblioitems.itemtype IN ( $in_string ) 
                    OR
                    items.itype IN ( $in_string )
                )
                AND items.itype NOT IN ( 'ILL', 'ILL7' )
            };
        }

        if (@locations) {
            my $in_string = join(',', map {"\"$_\""} @locations);
            $query .= qq{
                AND items.location IN ( $in_string )
            };
        }

        if (@ccodes) {
            my $in_string = join(',', map {"\"$_\""} @ccodes);
            $query .= qq{
                AND items.ccode IN ( $in_string )
            };
        }

        if ($branchcode) {
            $query .= q{
                AND homebranch = ?
            };
            push(@parameters, $branchcode);
        }

        $query .= q{
            GROUP BY subject, biblionumber ORDER BY subject, biblio.author, REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")
        };

        warn "QUERY: " . Data::Dumper::Dumper($query);
        warn "PARAMS: " . Data::Dumper::Dumper(@parameters);
        my $sth = C4::Context->dbh->prepare($query);
        $sth->execute(@parameters);

        my @items;
        while (my $s = $sth->fetchrow_hashref) {
            $s->{biblio} = Koha::Biblios->find($s->{biblionumber});

            # Get ALL items matching the search criteria
            my $item_search = {};
            $item_search->{permanent_location} = \@locations if @locations;
            $item_search->{homebranch} = $branchcode if $branchcode;
            $item_search->{itype} = \@itemtypes if @itemtypes;
            $item_search->{ccode} = \@ccodes if @ccodes;

            my $matching_items = $s->{biblio}->items->search($item_search);
            my @formatted_items;
            while (my $item = $matching_items->next) {
                my $formatted = $self->format_item($item, $item_format_template);
                push @formatted_items, $formatted if $formatted;
            }

            $s->{formatted_title} = $self->format_title($s->{biblio}, $title_format_template);
            $s->{formatted_author} = $self->format_author($s->{biblio}, $author_format_template);
            $s->{formatted_item} = join(', ', @formatted_items);  # Join all items with comma-space
            $s->{series}           = $self->get_series($s->{biblio});

            if (@itemtypes) {
                my $biblio = $s->{biblio};
                my @itypes = $biblio->items->get_column('itype');
                my @isect  = intersect(@itypes, @itemtypes);
                next unless @isect;
            }

            push(@items, $s);
        }
        # Sort all items by subject, then title within each subject
        @items = sort {
            $a->{subject} cmp $b->{subject}
            ||
            do {
                (my $ta = lc($a->{formatted_title} // '')) =~ s/^(the|an|a)\s+//;
                (my $tb = lc($b->{formatted_title} // '')) =~ s/^(the|an|a)\s+//;
                $ta cmp $tb
            }
        } @items;
        $items = \@items;
    } else {
        my $search_params = {};
        $search_params->{permanent_location} = \@locations if @locations;
        $search_params->{homebranch}         = $branchcode if $branchcode;
        $search_params->{itype}              = \@itemtypes if @itemtypes;

        my $order_by
            = $display_by eq 'title'  ? \'REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")'
            : $display_by eq 'title_series' ? \'REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")'
            : $display_by eq 'author' ? {-asc => 'biblio.author'}
            : $display_by eq 'callnumber' ? {-asc => 'me.itemcallnumber'}
            :                           \'REGEXP_REPLACE(biblio.title, "^(The|An|A)[[:space:]]+", "")';

        my @p = ($search_params, {prefetch => {'biblio' => 'biblio_metadatas'}, order_by => $order_by});
        warn "SEARCH PARAMS: " . Data::Dumper::Dumper(\@p);
        $items = Koha::Items->search(@p);
        warn "AS QUERY: " . Data::Dumper::Dumper($items->_resultset->as_query);

        $status->{count} = $items->count;
        my @items_array;
        while (my $item = $items->next) {
            my $item_data = {
                biblionumber => $item->biblionumber,
                biblio => $item->biblio,
                itemcallnumber => $item->itemcallnumber,
                formatted_title => $self->format_title($item->biblio, $title_format_template),
                formatted_author => $self->format_author($item->biblio, $author_format_template),
                formatted_item => $self->format_item($item, $item_format_template),
                series           => $self->get_series($item->biblio),
            };
            push @items_array, $item_data;
        }
    $items = \@items_array;
    }

    $status->{status}  = 'Generating HTML';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    $template->param(
        items => $items, 
        locations => \@locations, 
        homebranch => $branchcode, 
        displayby => $display_by,
        display_columns => join('|', $cgi->multi_param('display_columns')) || 'title|author|call_number',
        title_format => $self->retrieve_data('title_format') || '[% biblio.title | html %]',
        author_format => $self->retrieve_data('author_format') || '[% biblio.author | html %]',
        item_format => $self->retrieve_data('item_format') || '[% item.itemcallnumber | html %]',
    );

    my $ok = $template->{TEMPLATE}->process($template->filename, $template->{VARS}, $afh);
    $status->{error} = "Template process failed: " . $template->{TEMPLATE}->error() unless $ok;

    $status->{status}  = 'Generating PDF';
    $status->{updated} = dt_from_string()->iso8601;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);

    my $pdf_file = $html_file;
    $pdf_file =~ s/html$/pdf/;

    # Generate title with sort order and one key filter
    my $list_title = "Book List";

    # Add one key filter (first available)
    if ($branchcode) {
        my $branch = Koha::Libraries->find($branchcode);
        $list_title = $branch->branchname . " Books" if $branch;
    } elsif (@itemtypes && scalar(@itemtypes) == 1) {
        $list_title = $itemtypes[0] . " Books";
    } elsif (@ccodes && scalar(@ccodes) == 1) {
        $list_title = $ccodes[0] . " Books";
    }

    if (@locations) {
        my $loc_string = join(', ', @locations);
        $list_title .= " - $loc_string";
    }

    # Add sort order
    $list_title .= " by Author" if $display_by eq 'author';
    $list_title .= " by Title" if $display_by eq 'title';
    $list_title .= " by Title (Series)"   if $display_by eq 'title_series';
    $list_title .= " by Call Number" if $display_by eq 'callnumber';
    $list_title .= " by Subject" if $display_by =~ /^subject/;
    $list_title .= " by Subject (Series)" if $display_by eq 'subject655_series';

    my $command
    = qq{/usr/local/bin/wkhtmltopdf --encoding utf-8 --disable-smart-shrinking --page-size letter --header-center "$list_title" --header-left "Page [page] of [toPage]" --header-right "Date: [date]" --header-line --header-spacing 5 --header-font-size 12 --footer-spacing 4 --footer-left "" --footer-right '' --footer-font-size 10 --margin-top 15mm --margin-bottom 10mm --margin-left 10mm --margin-right 10mm $html_file $pdf_file 2>&1};
    my $output = qx($command);
    my $rc     = $?;
    $rc = $rc >> 8 unless ($rc == -1);
    $status->{error} = $output if $rc;

    $status->{status}      = 'Finished';
    $status->{updated}     = dt_from_string()->iso8601;
    $status->{pdf_file}    = $pdf_file;
    $status->{html_file}   = $html_file;
    $status->{html_output} = $output;
    DumpFile($status_file, $status);
    warn Data::Dumper::Dumper($status);
}

sub report_status {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);

    my $filename = $data->{pdf_file} || $data->{html_file};
    my $bytes    = (stat $filename)[7];
    $data->{current_file_size} = $bytes;

    $self->output_html(to_json($data));
}

sub report_download {
    warn "REPORT DOWNLOAD";
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $type = $cgi->param('type');

    my $file = $cgi->param('status');
    warn "FILE: $file";
    my $data = LoadFile($file);
    warn Data::Dumper::Dumper($data);

    if ($type eq 'pdf') {
        my $filename = $data->{pdf_file};
        warn "PDF FILE: $filename";

        my $bytes = (stat $filename)[7];

        print $cgi->header(
            -attachment => "list.pdf",
            -type       => 'application/pdf',

            #-Content_Disposition => "attachment; filename=list.pdf",
            -Content_Length => "$bytes"
        );

        open FILE, "< $filename" or die "can't open : $!";
        binmode FILE;
        local $/ = \10240;
        while (<FILE>) {
            print $_;
        }
        close FILE;

        unlink $data->{pdf_file};
    } elsif ($type eq 'html') {
        my $filename = $data->{html_file};
        warn "HTML FILE: $filename";

        my $bytes = (stat $filename)[7];

        print $cgi->header(
            -attachment => "list.html",

            #-Content_Disposition => "attachment; filename=list.pdf",
            -Content_Length => "$bytes"
        );

        open FILE, "< $filename" or die "can't open : $!";
        binmode FILE;
        local $/ = \10240;
        while (<FILE>) {
            print $_;
        }
        close FILE;

        unlink $data->{html_file};
    }

}

sub is_cmd_installed {
    my $check = `sh -c 'command -v /usr/local/bin/$_[0]'`;
    return $check;
}

sub cronjob_nightly {
    my ($self) = @_;
    warn "Koha::Plugin::Com::ByWaterSolutions::BookListPrinter::cronjob_nightly";

    my $dbh = C4::Context->dbh;

    my $subject_depth = $self->retrieve_data('subject_depth');

    my $delete_sth = $dbh->prepare(q{DELETE FROM plugin_book_list_printer_subjects WHERE biblionumber = ?});
    my $insert_sth = $dbh->prepare(q{INSERT INTO plugin_book_list_printer_subjects VALUES ( ?, ?, ?, ? )});

    my $biblios = Koha::Biblios->search();
    while (my $biblio = $biblios->next()) {
        warn "WORKING ON BIBLIO " . $biblio->id;
        my @subjects;    # We want to limit to only 3 subjects per bib

        my $rec;
        try {
            $rec = $biblio->metadata->record;
        } catch {
            warn "ERROR: BAD RECORD";
            next;
        };
        next unless $rec;

        # First, look for a first 655
        if (my $f = $rec->field('655')) {
            my @fields;
            push(@fields, $f->subfield('a')) if $f->subfield('a');
            my $s = join(' - ', @fields);
            warn "FOUND SUBJECT $s";
            push(@subjects, {subject => $s, tag => '655'}) if @fields;
        }

        # Next, fill the subjects list with 650's
        my @f = $rec->field('650');
        foreach my $f (@f) {
            next if scalar @subjects >= $subject_depth;

            my @fields;

            push(@fields, $f->subfield('a')) if $f->subfield('a');
            push(@fields, $f->subfield('x')) if $f->subfield('x');
            my $s = join(' - ', @fields);
            warn "FOUND SUBJECT $s";
            push(@subjects, {subject => $s, tag => '650'}) if @fields;
        }

        if (@subjects) {
            $delete_sth->execute($biblio->id);
            my $i = 0;
            foreach my $s (@subjects) {
                $insert_sth->execute($biblio->id, $i, $s->{tag}, $s->{subject});
                $i++;
            }
        }
    }
}

sub format_title {
    my ($self, $biblio, $title_format_template) = @_;
    
    return $biblio->title unless $title_format_template;
    
    my $output;
    eval {
        $output = C4::Letters::_process_tt({
            content => $title_format_template,
            objects => { biblio => $biblio },
        });
    };
    
    if ($@) {
        warn "Title format error: $@";
        return $biblio->title;
    }
    
    return $output || $biblio->title;
}

sub format_author {
    my ($self, $biblio, $author_format_template) = @_;
    
    return $biblio->author unless $author_format_template;
    
    my $output;
    eval {
        $output = C4::Letters::_process_tt({
            content => $author_format_template,
            objects => { biblio => $biblio },
        });
    };
    
    if ($@) {
        warn "Author format error: $@";
        return $biblio->author;
    }
    
    return $output || $biblio->author;
}

sub format_item {
    my ($self, $item, $item_format_template) = @_;
    
    # Default to item call number if no template provided
    return $item->itemcallnumber unless $item_format_template;
    
    my $output;
    eval {
        $output = C4::Letters::_process_tt({
            content => $item_format_template,
            objects => { item => $item },
        });
    };
    
    # On error, log and fall back to call number
    if ($@) {
        warn "Item format template error: $@";
        return $item->itemcallnumber;
    }
    
    # Return formatted output, or call number if output is empty
    return $output || $item->itemcallnumber;
}

sub get_series {
    my ($self, $biblio) = @_;

    my $rec;
    eval { $rec = $biblio->metadata->record };
    return '' unless $rec;

    my @series_parts;
    for my $f ($rec->field('490')) {
        my $title  = $f->subfield('a') // '';
        my $volume = $f->subfield('v') // '';
        $title  =~ s/\s*[,;:\/]\s*$//;  # strip trailing punctuation
        $volume =~ s/\s*[,;:\/]\s*$//;

        my $s = $title;
        $s   .= ", $volume" if $volume;
        push @series_parts, $s if $s;
    }

    return join('; ', @series_parts);
}

sub install {
    my ($self, $args) = @_;

    return C4::Context->dbh->do(q{
        CREATE TABLE `plugin_book_list_printer_subjects` (
            `biblionumber` INT(11) NOT NULL,
            `order` INT(11) NOT NULL DEFAULT '0',
            `tag` VARCHAR(3),
            `subject` VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
            KEY `bnidx` (`biblionumber`,`order`, `tag`),
            CONSTRAINT `bfk_borrowers` FOREIGN KEY (`biblionumber`) REFERENCES `biblio` (`biblionumber`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB;
    });
}

#my $schema = Koha::Database->new->schema;
#$schema->storage->debug(1);

1;
