#!/usr/bin/perl

use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::Log;
use HTML::FormatText;
use Time::Piece;
use Time::Seconds;
use XML::Feed;
use DateTime;
use DBI;
use utf8;

# non blocking - when i get around to moving in that direction
# https://metacpan.org/pod/Mojolicious::Guides::Cookbook#Synchronizing-events
# https://metacpan.org/pod/Mojolicious::Plugin::DefaultHelpers#delay
# https://metacpan.org/pod/Mojo::Pg

# load a config file that contains the apps
# configuration parameters
my $config = plugin 'Config';

our $VERSION = "1.7";

# turn off buffering
$| = 0;

# if the user wants to see extra debugging text
# set this value to 1
my $debug = $config->{debug};

# the parse RSS feed timeout variable
my $parse_timeout = $config->{parse_timeout};

my $now_time = localtime();

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$hour = "0" . $hour if $hour < 10;
$mon  = $mon + 1;
$mon  = "0" . $mon if $mon < 10;
$year = $year + 1900;

my %months = (
    Jan => '00', Feb => '01', Mar => '02',
    Apr => '03', May => '04', Jun => '05',
    Jul => '06', Aug => '07', Sep => '08',
    Oct => '09', Nov => '10', Dec => '11'
);

# hypnotoad server configuration
app->config (
    hypnotoad => {
        listen             => [$config->{ip_address_port}],
        pid_file           => $config->{pid_file},
        heartbeat_timeout  => $config->{heartbeat_timeout},
        heartbeat_interval => $config->{heartbeat_interval},
        inactivity_timeout => $config->{inactivity_timeout},
        workers            => $config->{workers},
    }
);

# setup the database connection
app->attr (
    dbh => sub {
        my $self        = shift;
        
        my $data_source = $config->{data_source};
        my $db_user     = $config->{data_source_user};
        my $db_pass     = $config->{data_source_pass};
        
        # database connection
        my $dbh = DBI->connect($data_source, $db_user , $db_pass);
        
        $dbh->{RaiseError}     = 1;
        $dbh->{PrintError}     = 0;
        $dbh->{sqlite_unicode} = 1;
        
        # turn on write ahead logging to help with performance - if necessary
        # $dbh->do("PRAGMA journal_mode=WAL;");
        
        return $dbh;
    }
);

# location for the log to be stored
my $log_dir = $config->{log_dir};

# if the log directory does not exist then create it
if ( ! -d $log_dir ) {
  print "Creating $log_dir directory\n";
  mkdir $log_dir, 0755 or die "Cannot create $log_dir: $!\n";
}

# setup Mojo logging to use the log directory we just created
# default the log level to info
my $log = Mojo::Log->new (path => "$log_dir/$config->{log_file}", level => $config->{log_level});

# ------------- NEWS HELPER FUNCTIONS -------------
    
# create the database
helper create_tables => sub {
    my $self = shift;

    $log->info("Creating rss tables");
    
    my $dbh = $self->app->dbh;
	
    $dbh->do(
        'create table if not exists rss_feeds (feed_id integer primary key, feed_name text, feed_url text)'
    );
        
    $dbh->do(
        'create table if not exists rss_news (
            news_id integer primary key, 
            feed_id integer, 
            news_date text, 
            news_title text, 
            news_desc text, 
            news_url text, 
            news_seen integer, 
            news_fav integer
        )'
    );
    
    $dbh->do('create index if not exists rss_feeds_idx on rss_feeds (feed_id)');
    $dbh->do('create index if not exists rss_news_idx on rss_news (news_id, feed_id, news_title)');
    
};

# Check if the the first table exists
# this helper will be used later when this script runs
# If the table does not exist it will be created then the
# rest of the script will continue
helper check_tables => sub {
    my $self = shift;

    $log->info("Checking if the tables exist");
    
    my $dbh = $self->app->dbh;
    
    my $ret = $dbh->prepare("SELECT count(name) FROM sqlite_master WHERE type = 'table' AND name = 'rss_feeds'");
    $ret->execute();
    my @count = $ret->fetchrow_array();
    $ret->finish();

    return $count[0];

};

# SQL query for listing the RSS feeds
# this will only list feeds that actually have new news items
# to view
helper select_feeds => sub {
    my $self = shift;

    my $dbh = $self->app->dbh;

    my $get_feeds = $dbh->prepare('
        select
            rf.feed_id, rf.feed_name
        from
            rss_feeds rf
        where
            rf.feed_id in
                (select
                    rfx.feed_id
                from
                    rss_feeds rfx
                INTERSECT
                select
                    rn.feed_id
                from
                    rss_news rn
                where
                    rn.news_seen = 0
                group by
                    rn.feed_id
                having
                    count(*) > 0
                )
        order by
            rf.feed_name asc
        ');
	
    $get_feeds->execute();
    my $ret_feeds = $get_feeds->fetchall_arrayref;
    $get_feeds->finish();
    
    return $ret_feeds;

};

# SQL query to view the unread news items for a RSS feed
# do not show any fav'ed news items
helper select_news => sub {
    my $self        = shift;
    my $rss_feed_id = shift;
	
    my $dbh = $self->app->dbh;
	
    my $get_news = $dbh->prepare('
        select
            rf.feed_name, rn.news_date, rn.news_title, rn.news_desc, rn.news_url, rn.news_id
        from
            rss_feeds rf, rss_news rn
        where
            rn.feed_id = ? and rf.feed_id = ?
            and rn.news_seen = 0
        order by
            rn.news_date desc
    ');

    $get_news->execute($rss_feed_id, $rss_feed_id);
    my $ret_select = $get_news->fetchall_arrayref;
    $get_news->finish();
    
    return $ret_select;
	
};

# SQL query to select only the fav'ed news items
helper select_favs => sub {
    my $self = shift;
	
    my $dbh = $self->app->dbh;
	
    my $get_favs = $dbh->prepare('
    select
        rf.feed_name, rn.news_date, rn.news_title, rn.news_desc, rn.news_url, rn.news_id
    from
        rss_feeds rf, rss_news rn
    where
        rn.feed_id = rf.feed_id
        and rn.news_fav = 1
    order by
        rn.news_date desc
    ');

    $get_favs->execute();
    my $ret_favs = $get_favs->fetchall_arrayref;
    $get_favs->finish();
    
    return $ret_favs;

};

# Get the current count of feeds in the database
helper count_feeds => sub {
    my $self = shift;
	
    my $dbh = $self->app->dbh;

    my $feed_count = $dbh->prepare("select count(*) from rss_feeds");
    $feed_count->execute();
    my @count = $feed_count->fetchrow_array();
    $feed_count->finish();
    
    return $count[0];
    
};

# SQL query to list all the RSS feeds
helper edit_feed_list => sub {
    my $self = shift;
	
    my $dbh = $self->app->dbh;
	
    my $get_feeds = $dbh->prepare('
            select feed_id, feed_name, feed_url from rss_feeds order by feed_name asc
            ');
		
    $get_feeds->execute();
    my $ret_feeds = $get_feeds->fetchall_arrayref;
    $get_feeds->finish();
    
    return $ret_feeds;
};

helper add_news_feed => sub {
    my $self      = shift;
    my $feed_name = shift;
    my $feed_url  = shift;
    
    my $dbh = $self->app->dbh;
    my $insert_feed = $dbh->prepare('insert into rss_feeds (feed_name, feed_url) values (?, ?)');
    $insert_feed->execute($feed_name, $feed_url);
    $insert_feed->finish();
};

helper update_news_item => sub {
    my $self        = shift;
    my $feed_id     = shift;
    my $feed_update = shift;
    my $update;
    
    my $dbh = $self->app->dbh;

    if ( $feed_update eq "seen" ) {
        $update = $dbh->prepare('update rss_news set news_seen = 1 where news_id = ?');
    } elsif ( $feed_update eq "seen_all" ) {
        $update = $dbh->prepare('update rss_news set news_seen = 1 where feed_id = ?');
    } elsif ( $feed_update eq "fav" ) {
        $update = $dbh->prepare('update rss_news set news_fav = 1, news_seen = 1 where news_id = ?');
    } elsif ( $feed_update eq "unfav" ) {
        $update = $dbh->prepare('update rss_news set news_fav = 0 where news_id = ?');
    }
    
    $update->execute($feed_id);
    $update->finish();
};

helper update_feed_item => sub {
    my $self     = shift;
    my $feed_id  = shift;
    my $feed_url = shift;
    
    my $dbh = $self->app->dbh;
    
    my $update = $dbh->prepare('update rss_feeds set feed_url = ? where feed_id = ?');    
    $update->execute($feed_url, $feed_id);
    $update->finish();
};

helper delete_news => sub {
    my $self    = shift;
    my $feed_id = shift;

    my $dbh = $self->app->dbh;
    
    my $delete_feed = $dbh->prepare('delete from rss_feeds where feed_id = ?');
    $delete_feed->execute($feed_id);
    $delete_feed->finish();

    my $delete_news = $dbh->prepare('delete from rss_news where feed_id = ?');
    $delete_news->execute($feed_id);
    $delete_news->finish();

    my $vacuum = $dbh->do('vacuum');
    if ( ! defined $vacuum ) {
        $log->info("delete_news - vacuum was undefined");
    }
    else {
        $log->info("delete_news - vacuum clearred $vacuum items") if $debug;
    }
};

helper cleanup_news => sub {
    my $self        = shift;
    my $remove_date = shift;

    my $dbh = $self->app->dbh;
		
    my $remove_old_news = $dbh->prepare("update rss_news set news_desc = NULL where news_date <= ? and news_fav = '0'");
    $remove_old_news->execute($remove_date);
    $remove_old_news->finish();	

    my $vacuum = $dbh->do('vacuum');
    if ( ! defined $vacuum ) {
        $log->info("cleanup_news - vacuum was undefined");
    }
    else {
        $log->info("cleanup_news - vacuum clearred $vacuum items") if $debug;
    }
    
};

# if the index does not exist then create the tables
# else just run the select feeds helper
if ( app->check_tables == 0 ) {
    app->create_tables;
}
app->select_feeds;

# ------------- NEWS UPDATE ROUTE -------------

# EventSource for log messages
get '/events' => sub {
    my $self = shift;

    # Increase inactivity timeout for connection a bit
    # $self->inactivity_timeout(300);

    # Change content type
    $self->res->headers->content_type('text/event-stream');

    # Subscribe to "message" event and forward "log" events to browser
    my $cb = $self->app->log->on(message => sub {
        my ($log, $level, @lines) = @_;
        $self->write("event:log\ndata: [$level] @lines\n\n");
    });
    
    # Unsubscribe from "message" event again once we are done
    $self->on(finish => sub {
       my $self = shift;
       $self->app->log->unsubscribe(message => $cb);
    });
};

# ------------- NEWS ROUTES -------------

# this route will show the RSS feeds
any '/' => sub {
    my $self = shift;
	
    my $rows = $self->select_feeds;
    $self->stash( feed_rows => $rows );
    $self->render('list_feeds');
};

# show the list of news from the feed
# :feed is the feed_number from the database
# :name is the name shown from the list of RSS feeds
get '/view_news/:feed/:name' => sub {
    my $self      = shift;
    my $news_id   = $self->param('feed');
    my $news_name = $self->param('name');
    
    my $news_rows = $self->select_news($news_id);
    $self->stash(news_rows => $news_rows);
    $self->stash(news_id   => $news_id);
    $self->stash(news_name => $news_name);    
    $self->render('rss');
};

# show the news items the user chose to favorite
get '/favs' => sub {
    my $self = shift;
	
    my $rows = $self->select_favs;
    $self->stash( fav_rows => $rows );
    $self->render('favs');
};

# edit the RSS feed list
get '/edit_feeds' => sub {
    my $self = shift;
	
    my $rows = $self->edit_feed_list;
    $self->stash( edit_rows => $rows );
    $self->render('edit_feeds');
};

# show the page that will allow the user to
# 1. add a RSS feed
# 2. edit RSS feeds
# 3. delete RSS news items  that have not be fav'ed
get '/maint_feeds' => sub {
    my $self = shift;
	
    my $rows = $self->edit_feed_list;
    $self->stash( edit_rows => $rows );
    $self->render('maint');
};


# add a RSS feed to the database
get '/add_feeds' => sub {
    my $self      = shift;
    my $feed_name = $self->param('feed_name');
    my $feed_url  = $self->param('feed_url');

    $self->add_news_feed($feed_name, $feed_url);
    return $self->render(text => 'done', status => 200);
};

# Change state of RSS news item depending on user access
# seen     - mark an individual news item read
# seen_all - mark all news items under a feed as read
# fav      - mark a news item as a favorite
# unfav    - unfavorite a previously fav'ed item
get '/update_news' => sub {
    my $self        = shift;
    my $feed_id     = $self->param('feed_id');
    my $feed_update = $self->param('feed_type');

    $self->update_news_item($feed_id, $feed_update);
    return $self->render(text => 'done', status => 200);
};

# update a RSS feed URL
get '/update_feed' => sub {
    my $self     = shift;
    my $feed_id  = $self->param('feed_id');
    my $feed_url = $self->param('feed_url');

    $self->update_feed_item($feed_url, $feed_id);
    return $self->render(text => 'done', status => 200);    
};

# delete a RSS feed as well as all news items from that feed
get '/delete_feed' => sub {
    my $self    = shift;
    my $feed_id = $self->param('feed_id');

    $self->delete_news($feed_id);    
    return $self->render(text => 'done', status => 200);
};

# remove only the actual detail of the news as it takes up the most space
# and because the title is used to determine if we already downloaded an
# existing news item
get '/cleanup' => sub {
    my $self      = shift;
    my $days_back = $self->param('days_back');

    # find the datetime stamp some number of days back
    # days back is provided by the user
    my $current_time = localtime;    
    $current_time -= ( $days_back * ONE_DAY );
    my $remove_date = $current_time->datetime;

    $self->cleanup_news($remove_date);   
    return $self->render(text => 'done', status => 200);
};

# iterate over all RSS feeds add news items to the
# database
# as a way to keep a web server from timing out
# only cycle 10 feeds at a time.  the SQL query uses
# the limit capability to move to the next group of
# RSS feeds
get '/add_news' => sub {
    
    my $self = shift;
    
    $log->info("---------- Start group of feeds ----------") if $debug;

    my $dbh = $self->app->dbh;
    
    # read in the SQL offset if one exists so we
    # only read 10 feeds at a time.  if no offset
    # is provided then start at 0
    my $offset = $self->param('offset') // 0;
    
    $log->info("offset = $offset") if $debug > 9;
    
    # get the total number of feeds we have and then add 10 to it
    # so that we can create the fail condition when there are no
    # more feeds left
    my $total_feeds = $self->count_feeds;
    $total_feeds += 10;
        
    # get the feeds to update 10 at a time
    my $get_feeds = $dbh->prepare("select feed_id, feed_name, feed_url from rss_feeds LIMIT 10 OFFSET ?");
    $get_feeds->execute($offset);
    
    # setup the offset for the next call if there is one
    if ( $offset == 0 ) {
        $offset = 10;
    } else {
        $offset += 10;
    }
    
    # update a div with $offset / $total_feeds
    # may use a mojo eventsource or maybe a json endpoint (are these the same things?) to update a div
    # in the html
    $log->info("$offset of $total_feeds");
    
    $log->info("offset after update = $offset") if $debug > 9;
    
    # prepare queries for inserting news and also finding items that may already exist in the database
    my $insert_news = $dbh->prepare("insert into rss_news (feed_id,news_date,news_title,news_desc,news_url,news_seen,news_fav) values (?, ?, ?, ?, ?, ?, ?)");
    my $find = $dbh->prepare("select count(*) from rss_news where news_title = ? and feed_id = ?");

    # iterate over each RSS feed
    while ( my @feed_data = $get_feeds->fetchrow_array() ) {

        my $rss_id   = $feed_data[0];
        my $rss_name = $feed_data[1];
        my $rss_url  = $feed_data[2];
        
        $log->info("$rss_name - head request") if $debug;

        # check that the URL exists by doing a HEAD against the URL
        # if there is a problem access a feed skip to the next feed
        my $ua = Mojo::UserAgent->new;
        if ( ! defined $ua ) {
            $log->info("    UA not defined") if $debug;
            next;
        }

        my $tx = $ua->head($rss_url);
        if ( ! defined $tx ) {
            $log->info("    head request failed") if $debug;
            next;
        }

        # Check the result code of the HEAD request.  I have found that even when 
        # a 501 is returned the RSS feed may still work.  If a 200 or 501 is not returned
        # then insert a defaul future date bad url message.  This will allow the user to know
        # there was a problem
        if ( defined $tx->res->code && $tx->res->code !~ /200|501/ ) {
            
            # feed_id, news_date, news_title, news_desc, news_url
            # $insert_news->execute($rss_id, '2099-01-01 00:00:00:000', 'bad url', $rss_url, '', 0, 0);
            
            $log->info("    skipping") if $debug;
            next;
        }

        $log->info("    About to parse the RSS URL - $rss_url") if $debug > 9;

        # Attempt to get the RSS feed.  If it works save it to $feed
        # otherwise skip to the next feed
        my $feed;
        eval {
            # setup an alarm to skip this process if it takes longer than XX seconds
            local $SIG{ALRM} = sub { $log->info("    Taking too long, skipping"); next; };
            alarm $parse_timeout;
            # the URL is good so pull it
            $feed = XML::Feed->parse(URI->new($rss_url));
            alarm 0;
        };
        
        if ( $@ ) {
            $log->info("    There was a problem parsing $rss_url") if $debug;
            next;
        }
            
        if ( ! defined $feed ) {
            $log->info("    Cannot parse $rss_url") if $debug;
            next;
        }

        $log->info("    URL parsed") if $debug > 9;

        # iterate over each news item of the RSS feed
        foreach my $story ($feed->entries) {
           
            my $dt      = 0;
            my $date    = 0;
            my $year    = 0;
            my $month   = 0;
            my $day     = 0;
            my $day_num = 0;
            my $time    = 0;
            my $hour    = 0;
            my $minute  = 0;
            my $second  = 0;
 
            # if the feed includes a date use it
            # if not create our own using the current time
            if ( defined $story->issued ) {
                $date  = $story->issued;
            } else {
                $dt     = DateTime->now;
                $year   = $dt->year;
                $month  = $dt->month  < 10 ? '0' . $dt->month  : $dt->month;
                $day    = $dt->day    < 10 ? '0' . $dt->day    : $dt->day;
                $hour   = $dt->hour   < 10 ? '0' . $dt->hour   : $dt->hour;
                $minute = $dt->minute < 10 ? '0' . $dt->minute : $dt->minute;
                $second = $dt->second < 10 ? '0' . $dt->second : $dt->second;
                $date   = "$year-$month-$day" . "T" . "$hour:$minute:$second";
            }
            
            # get the news item title and if it does not exist prvide a
            # place holder title
            my $title = $story->title;
            $title    = "Empty title" if ! defined $title;

            # get the news for the specific item and if it does not exist prvide a
            # place holder text field    
            my $desc  = $story->content->body;
            $desc     = "Empty body" if ! defined $desc;
            
            my $url   = $story->link;
            $url      = $rss_url if ! defined $url;

            # Clear up HTML and remove image tags to clear up what you view
            my $desc_string = HTML::FormatText->format_string($desc);
            $desc_string =~ s/\[IMAGE\]//g;
            $desc_string =~ s/\s+$/\n\n/;

            # Have we already downloaded this news item?
            # Check by lookin at the RSS news item title
            $find->execute($title, $rss_id);
            my @count = $find->fetchrow_array();
            
            # if the article does not exist in the database then add it
            # otherwise skip it
            if ( $count[0] == 0 ) {
                $log->info("    Adding news") if $debug > 19;
                $insert_news->execute($rss_id, $date, $title, $desc_string, $url, 0, 0);
                $log->info("    News added") if $debug > 19;
            }
            else {
                $log->info("    News already exists") if $debug > 19;
            }
            
        } # END foreach my $story ($feed->entries) {

    } # END while ( my @feed_data = $get_feeds->fetchrow_array() ) {

    $log->info("offset = $offset and total_feeds = $total_feeds") if $debug > 19;

    # finish commands so that we start fresh on the next go around
    # or when we are done adding news

    $log->info("before query finish") if $debug > 19;

    $get_feeds->finish();
    $insert_news->finish();
    $find->finish();

    $log->info("after query finish") if $debug > 19;

    # the recursive call used to keep gathering news
    # until we have gathered all the feeds we have
    if ( $offset >= $total_feeds ) {        
        $log->info("about to redirect to /") if $debug > 9;
        $self->redirect_to('/');
    } else {
        $log->info("redirect - /add_news?offset=$offset") if $debug > 9;
        $self->redirect_to("/add_news?offset=$offset");
    }

};

app->start;

# ------------- HTML TEMPLATES -------------

__DATA__
@@list_feeds.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>News Feeds</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <script>
            function goURL(url) {
                var xmlhttp;
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        if ( url === "/add_news" ) {
                            document.getElementById('updateButtonTop').disabled = '';
                            document.getElementById('updateButtonBot').disabled = '';
                            window.location.href = "/";
                        } else {
                            window.location.href = url;
                        }
                    }
                }

                if ( url === "/add_news" ) {
                    document.getElementById('updateButtonTop').disabled = 'disabled';
                    document.getElementById('updateButtonBot').disabled = 'disabled';
                }

                xmlhttp.open("GET", url, true);
                xmlhttp.send();                    
            }
            
            var events = new EventSource('<%= url_for 'events' %>');

            // Subscribe to "log" event
            events.addEventListener('log', function(event) {
                // document.body.innerHTML += event.data + '<br/>';
                document.getElementById('event_update').innerHTML = event.data;
            }, false);
        </script>
        <style>
            %= include 'rss_style'
        </style>
    </head>
    <body>
        %= include 'header'
        <div id='event_update'></div>
        % foreach my $row ( @$feed_rows ) {
		% my ($row_feed_id, $row_feed_name) = @$row;
		% $row_feed_name =~ s/\./ /g;
		<div class='feedlink'><a href='/view_news/<%= $row_feed_id %>/<%= $row_feed_name %>'><%= $row_feed_name %></a></div><br>
        % }
        %= include 'footer'
    </body>
</html>

@@rss.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>News</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <style>
            %= include 'rss_style'
        </style>
        <script>
            function goURL(url) {
                var xmlhttp;
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        if ( url === "/add_news" ) {
                            document.getElementById('updateButtonTop').disabled = '';
                            document.getElementById('updateButtonBot').disabled = '';
                            window.location.href = "/";
                        } else {
                            window.location.href = url;
                        }
                    }
                }

                if ( url === "/add_news" ) {
                    document.getElementById('updateButtonTop').disabled = 'disabled';
                    document.getElementById('updateButtonBot').disabled = 'disabled';
                }

                xmlhttp.open("GET", url, true);
                xmlhttp.send();                    
            }
            
            function changeState(state, id, link_id) {
                var xmlhttp;
                
                setCookie('link_id', link_id, 5000);
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        if ( state == "seen_all" ) {
                            window.location.href = "/";
                        } else {
                            window.location.reload(true);
                        }
                    }
                }
                
                xmlhttp.open("GET","/update_news?feed_id=" + id + "&feed_type=" + state, true);
                xmlhttp.send();
            }
            
            function setCookie(c_name,value,extime) {
                var e_poch = new Date().valueOf();
                var exdate = e_poch + extime;
                var expireDate = new Date(exdate);
                var c_value = escape(value) + ((extime==null) ? "" : ";expires="+expireDate);
                document.cookie = c_name + "=" + c_value;
            }

            function getCookie(name) {
                var nameEQ = name + "=";
                var ca = document.cookie.split(';');
                for (var i = 0; i < ca.length; i++) {
                    var c = ca[i];
                    while (c.charAt(0) == ' ') c = c.substring(1, c.length);
                    if (c.indexOf(nameEQ) == 0) return c.substring(nameEQ.length, c.length);
                }
                return null;
            }

            function checkCookie() {
              var link_id = getCookie("link_id");
              var go_link = 0;
              if (link_id != null && link_id != "") {
                  if ( link_id == 0 ) {
                      go_link = 'top';
                  } else {
                      go_link = link_id - 1;
                  }
                  var curr_href_hold = window.location.href;
                  curr_href = curr_href_hold.split("#");
                  window.location.href = curr_href[0] + "#" + go_link;
              }
            }
        </script>
    </head>
    <body onload="checkCookie()">
        <a id='top'></a>
        %= include 'header'
        <p />
        <div class='header'>
            <b><%= $news_name %></b>&nbsp;&nbsp;&nbsp;&nbsp;
            <button type="button" onClick="changeState('seen_all', <%= $news_id %>)">All Read</button>
        </div>
        <table>
        % my $counter = 0;
        % foreach my $row ( @$news_rows ) {
            % my ( $feed_name, $news_date, $news_title, $news_desc, $news_url, $news_id ) = @$row;
            <tr>
                <td>
                    <div>
                        % if ( $counter > 4 ) {
                            <a href='#top'>Top</a>&nbsp;&nbsp;
                        % }
                        <a id='<%= $counter %>'></a>    
                        <b><a href='<%= $news_url %>' target='_blank'><%= $news_title %></a></b><!-- <%= $news_date %> -->
                        <p />
                        <button type="button" onClick="changeState('seen', <%= $news_id %>, '<%= $counter %>')">Read</button>
                        &nbsp;&nbsp;&nbsp;&nbsp;
                        <button type="button" onClick="changeState('fav', <%= $news_id %>, '<%= $counter %>')">Fav</button>
                        <br>
                        <div class='news'>
                            <%= $news_desc %>
                        </div>
                    </div>
                </td>
            </tr>
            % $counter++;
        % }
        </table>
        %= include 'footer'
    </body>
</html>

@@ favs.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>Favorite News</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <style>
            %= include 'rss_style'
        </style>
        <script>
            function goURL(url) {
                var xmlhttp;
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        if ( url === "/add_news" ) {
                            document.getElementById('updateButtonTop').disabled = '';
                            document.getElementById('updateButtonBot').disabled = '';
                            window.location.href = "/";
                        } else {
                            window.location.href = url;
                        }
                    }
                }

                if ( url === "/add_news" ) {
                    document.getElementById('updateButtonTop').disabled = 'disabled';
                    document.getElementById('updateButtonBot').disabled = 'disabled';
                }

                xmlhttp.open("GET", url, true);
                xmlhttp.send();                    
            }
            
            function changeState(state, id, fav_id) {
                var xmlhttp;

                setCookie('fav_id', fav_id, 5000);

                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        window.location.reload(true);
                    }
                }
            
                xmlhttp.open("GET","/update_news?feed_id=" + id + "&feed_type=" + state, true);
                xmlhttp.send();            
            }
            
            function setCookie(c_name,value,extime) {
                var e_poch = new Date().valueOf();
                var exdate = e_poch + extime;
                var expireDate = new Date(exdate);
                var c_value = escape(value) + ((extime==null) ? "" : ";expires="+expireDate);
                document.cookie = c_name + "=" + c_value;
            }

            function getCookie(name) {
                var nameEQ = name + "=";
                var ca = document.cookie.split(';');
                for (var i = 0; i < ca.length; i++) {
                    var c = ca[i];
                    while (c.charAt(0) == ' ') c = c.substring(1, c.length);
                    if (c.indexOf(nameEQ) == 0) return c.substring(nameEQ.length, c.length);
                }
                return null;
            }

            function checkCookie() {
              var fav_id = getCookie("fav_id");
              var go_fav = 0;
              if (fav_id != null && fav_id != "") {
                  if ( fav_id == 0 ) {
                      go_fav = 'top';
                  } else {
                      go_fav = fav_id - 1;
                  }
                  var curr_href_hold = window.location.href;
                  curr_href = curr_href_hold.split("#");
                  window.location.href = curr_href[0] + "#" + go_fav;
              }
            }

        </script>
    </head>
    <body onload="checkCookie()">
        <a id='top'></a>
        %= include 'header'
        <p />
        <table>
        % my $counter = 0;
        % foreach my $row ( @$fav_rows ) {
            % my ( $feed_name, $news_date, $news_title, $news_desc, $news_url, $news_id ) = @$row;
            <tr>
                <td>
                    <div>
                        % if ( $counter > 4 ) {
                            <a href='#top'>Top</a>&nbsp;&nbsp;
                        % }
                        <a id='<%= $counter %>'></a> 
                        <b><a href='<%= $news_url %>' target='_blank'><%= $news_title %></a></b><!-- <%= $news_date %> -->
                        <p />
                        <button type="button" onClick="changeState('unfav', <%= $news_id %>, <%= $counter %>)">UnFav</button>
                        <br>
                    </div>
                    <div class='news'>
                        <%= $news_desc %>
                    </div>
                </td>
            </tr>
            % $counter++;
        % }
        </table>
		%= include 'footer'
    </body>
</html>

@@ edit_feeds.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>Edit News Feeds</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <script>
            function goURL(url) {
                var xmlhttp;
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        if ( url === "/add_news" ) {
                            document.getElementById('updateButtonTop').disabled = '';
                            document.getElementById('updateButtonBot').disabled = '';
                            window.location.href = "/";
                        } else {
                            window.location.href = url;
                        }
                    }
                }

                if ( url === "/add_news" ) {
                    document.getElementById('updateButtonTop').disabled = 'disabled';
                    document.getElementById('updateButtonBot').disabled = 'disabled';
                }

                xmlhttp.open("GET", url, true);
                xmlhttp.send();                    
            }
        </script>        
        <style>
            %= include 'rss_style'
        </style>
    </head>    
    <body>
        %= include 'header'
        <p />
        <table>
        % foreach my $row ( @$edit_rows ) {
            % my ( $feed_id, $feed_name, $feed_url ) = @$row;
            <tr>
                <td><%= $feed_name %></td>
            </tr>
            <tr>
                <td>
                    <form action="<%=url_for('/update_feed')->to_abs%>" method="post" class="formWithButtons">
                        <input type='hidden' name='feed_id' value='<%= $feed_id %>'>
                        <input type='text' size='30' name='feed_url' value='<%= $feed_url %>'>
                        <input type='submit' value='Update'>
                    </form>
                    <form action="<%=url_for('/delete_feed')->to_abs%>" method="post" class="formWithButtons">
                        <input type='hidden' name='feed_id' value='<%= $feed_id %>'>
                        <input type='submit' value='Delete'>
                    </form>
                </td>
            </tr>
        % }
        </table>
        %= include 'footer'
    </body>
</html>

@@ add_feed.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>Manage Feeds</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <style>
            %= include 'rss_style'
        </style>
    </head>
    <body>
        %= include 'header'
        <form action="<%=url_for('/add_feeds')->to_abs%>" method="post">
        Feed Name: <input type="text" name="feed_name">
        <br> 
        Feed URL: <input type="text" name="feed_url">
        <br>
        <input type="submit" value="Add Feed"> 
        </form>
        %= include 'footer'
    </body>
</html>

@@maint.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>Manage Feeds</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <script>
            function goURL(url) {
                var xmlhttp;
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        if ( url === "/add_news" ) {
                            document.getElementById('updateButtonTop').disabled = '';
                            document.getElementById('updateButtonBot').disabled = '';
                            window.location.href = "/";
                        } else {
                            window.location.href = url;
                        }
                    }
                }

                if ( url === "/add_news" ) {
                    document.getElementById('updateButtonTop').disabled = 'disabled';
                    document.getElementById('updateButtonBot').disabled = 'disabled';
                }

                xmlhttp.open("GET", url, true);
                xmlhttp.send();                    
            }
                    
            function changeState(state, arg_one, arg_two) {
                var xmlhttp;
                
                if (window.XMLHttpRequest) {
                    xmlhttp = new XMLHttpRequest();
                } else {
                    xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
                }

                xmlhttp.onreadystatechange = function() {
                    if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
                        
                        if ( state == 'add' ) {
                            document.getElementById('feedAdd').innerHTML = 'Feed Added';
                            window.location.reload(true);
                        } else if ( state == 'clean' ) {
                            document.getElementById('cleanUp').innerHTML = 'Cleared';
                            document.getElementById('days_back').value = ''
                        } else if ( state == 'update' ) {
                            document.getElementById('feedChange').innerHTML = 'Feed Updated';
                            window.location.reload(true);
                        } else if ( state == 'delete' ) {
                            document.getElementById('feedChange').innerHTML = 'Feed Deleted';
                            window.location.reload(true);
                        } else {
                            alert('Incorrect state provided');
                        }
                    }
                }
                
                if ( state == 'add' ) {
                    
                    name = document.getElementById('add_feed_name').value;
                    url = document.getElementById('add_feed_url').value;
                    
                    xmlhttp.open("GET","/add_feeds?feed_name=" + name + "&feed_url=" + url, true);
                    xmlhttp.send();
                    
                } else if ( state == 'clean' ) {
                    
                    number = document.getElementById('days_back').value;
                    
                    xmlhttp.open("GET","/cleanup?days_back=" + number, true);
                    xmlhttp.send();
                    
                } else if ( state == 'update' ) {
                    
                    xmlhttp.open("GET","/update_feed?feed_id=" + arg_one + "&feed_url=" + arg_two, true);
                    xmlhttp.send();

                } else if ( state == 'delete' ) {
                    
                    xmlhttp.open("GET","/delete_feed?feed_id=" + arg_one, true);
                    xmlhttp.send();
                    
                }
            }
        </script>
        <style>
            %= include 'rss_style'
        </style>
    </head>
    <body>
        %= include 'header'
        
        <div class='column'>
            <fieldset>
                Feed Name: <input type="text" size='35' id="add_feed_name">
                <br> 
                Feed URL: <input type="url" size='35' id="add_feed_url">
                <br>
                <button type="button" onClick="changeState('add', '', '')">Add Feed</button>
                <div id='feedAdd'></div>
            </fieldset>
        </div>
        
        <div class='column'>
            <fieldset>
                Remove older than (days): <input type="number" size='2' id="days_back">
                <button type="button" onClick="changeState('clean', '', '')">Clean Up</button>
                <div id='cleanUp'></div>
            </fieldset>
        </div>
        
        <div class='clear'></div>
        
        <div class='column'>
            <fieldset>
                <div id='feedChange'></div>
                <table>
                % foreach my $row ( @$edit_rows ) {
                    % my ( $feed_id, $feed_name, $feed_url ) = @$row;
                    <tr>
                        <td><%= $feed_name %></td>
                    </tr>
                    <tr>
                        <td>
                            <form class='formWithButtons'>
                                <input type='hidden' name='feed_id' value='<%= $feed_id %>'>
                                <input type='text' size='35' name='feed_url' value='<%= $feed_url %>'>
                                <button type="button" onClick="changeState('update', '<%= $feed_id %>', '<%= $feed_url %>')">Update</button>
                            </form>
                            <form class="formWithButtons">
                                <input type='hidden' name='feed_id' value='<%= $feed_id %>'>
                                <button type="button" onClick="changeState('delete', '<%= $feed_id %>', '')">Delete</button>
                            </form>
                        </td>
                    </tr>
                % }
                </table>
            </div>
        </fieldset>
        
        %= include 'footer'
    </body>
</html>

@@ header.html.ep
<div style='padding-bottom: 40px;'>
<ul>
<li><button id='updateButtonTop' type="button" onClick="goURL('/add_news')">Update</button></li>
<li><button type="button" onClick="goURL('/maint_feeds')">Manage</button></li>
<li><button type="button" onClick="goURL('/')">Feed List</button></li>
<li><button type="button" onClick="goURL('/favs')">Favs</button></li>
</ul>
</div>
<div class='clear'></div>

@@ footer.html.ep
<p />
<a href='#top'>Top</a>
<div class='clear'></div>
<ul>
<li><button id='updateButtonBot' type="button" onClick="goURL('/add_news')">Update</button></li>
<li><button type="button" onClick="goURL('/maint_feeds')">Manage</button></li>
<li><button type="button" onClick="goURL('/')">Feed List</button></li>
<li><button type="button" onClick="goURL('/favs')">Favs</button></li>
</ul>
<div style='padding-bottom: 40px;'></div>

@@ rss_style.html.ep
@media all and (orientation: portrait) and (max-device-width: 480px) {
    body {
        max-width: 480px;
        font-size: 14px;
        background-color: black;
        color: white;
        margin-left: 10px;
    }
}

@media all and (orientation: portrait) and (max-device-width: 720px) {
    body {
        max-width: 720px;
        font-size: 14px;
        background-color: black;
        color: white;
        margin-left: 10px;
   }
}
    
@media all and (orientation: portrait) and (max-device-width: 1280px) {
    body {
        max-width: 1280px;
        font-size: 14px;
        background-color: black;
        color: white;
        margin-left: 10px;
    }
}
    
@media all and (orientation: landscape) and (max-device-width: 480px) {
    body {
        max-width: 480px;
        font-size: 14px;
        background-color: black;
        color: white;
        margin-left: 10px;
   }
}
    
@media all and (orientation: landscape) and (max-device-width: 720px) {
    body {
        max-width: 720px;
        font-size: 14px;
        background-color: black;
        color: white;
        margin-left: 10px;
   }
}

@media all and (orientation: landscape) and (max-device-width: 1280px) {
    body {
        max-width: 1280px;
        font-size: 14px;
        background-color: black;
        color: white;
        margin-left: 10px;
   }
}

fieldset {
   border-style: none;
   float: left;
}

.news {
    white-space: pre-line;
}

.header {
    margin-top: 2em;
    margin-bottom: 2em;
}

.feedlink {
    margin-top: .1em;
}

.update {
    visibility: hidden;
}

ul {
    float:left;
    padding:0;
    margin:0;
    list-style-type:none;
}

li {
    display:inline;
    padding-right: 20px;
}

.column {
   padding-left: 5px;
   padding-right: 5px;
}

.clear {
   clear: both;
   padding-bottom: 10px;
   margin-bottom: 10px;
}

tr:nth-child(even) {
    background: black
}

tr:nth-child(odd) {
    background: black;
}

a:link { color:white }
a:visited { color:white }
.formWithButtons { display:inline; }

__END__

=head1 NAME

rss.pl - Mojolicious based RSS news aggregator

=head1 SYNOPSIS

Single user, SQLite backed, Mojolicious based RSS news aggregator

=head1 DESCRIPTION

This is a web based single user RSS news aggregator that was created after Google closed down Reader.

=head1 README

This is a web based RSS news aggregator designed for a single user.  It uses Mojolicious as a web framework and SQLite has its database.  The interface is mobile friendly.  It does not require any extra web server as it can be used with Mojolicious' hypnotoad web server.  I currently run this script under OpenBSD 5.2 but there should be no problems with running it under Linux or other BSDs.

I used Google Reader quite a bit but when they closed it down I decided to write my own version.  This is the result of that desire.  I specifically wrote it for me and have not put any multi-user capability into the script.

When you first run the application it will create the necessary tables and their indexes if they do not exist.

=head1 USAGE

=head2 Main screen actions

=over 3

=item Update

Get the latest feeds by clicking Update

=item Favs

View your favorited items by click Favs

=item View

View the current RSS feeds by click View

=item Top

Go back to the top of a page be click Top at the bottom of the screen

=back

=head2 Viewing news for a feed

Click on the news name and the items for that feed will list

=head2 Options for reading and favoriting news items

If you want to mark all items of the feed being viewed as read then click All Read.  If you want to only mark an individual news itam as read then click Read under the title of a news title.  If you want to favorite a news item click Fav.

Once you get to the fifth news item and for each item there after you will have a link that says Top next to the news title.  Click this to go back to the top of the page.

=head2 Manage Feeds

You access feed management by clicking the Manage link.

=over 3

=item Add Feed

Add feed names and URLs and then click Add Feed

=item Delete

To remove RSS feeds find the feed in the list and click its Delete button

=item Update

To update a RSS feeds URL find the feed in the list fill in the new URL and click the Update button

=back

=head1 CONFIGURATION

SQlite does not require any configuration.  The first time you run the script the database will be created with the proper tables and indices.  The database resides in the same location as the script and it is called rss.db.

Mojolicious has a built in facility to use configuration files.  I have moved the script to use it so that I no longer need to edit the code when I want to change the IP address or pid file.  With moving to the config file I have added more options for configuration.  Here is the default config file.

 {
    # the IP address and port the Hypnotoad server listens
    ip_address_port => "http://IPADDRESS:PORT",
    # the datasource of the RSS database
    # the database file (rss.db) can be an absolute path
    data_source => "dbi:SQLite:dbname=rss.db",
    # the username and password to authenticate to the database
    # in SQLite's case you do not need a username
    data_source_user => undef, 
    data_source_pass => undef, 
    # the PID file hypnotoad will place its running PID
    # this can be an absolute path
    pid_file => "rss.pid",
    # the path and name of the logging directory
    # this can be an absolute path
    log_dir => "logs",
    # the name of the log file stored in log_dir
    log_file => "rss.log",
    # the Mojolicious Logging level
    log_level => 'info',
    # the application debug level for the log
    # 0 means no debug logging
    # 10 means more logging
    # 20 means even more logging
    debug => 0,
    # Mojolicious tuning - the timeout and interval are in seconds
    heartbeat_timeout => 60,
    heartbeat_interval => 10,
    inactivity_timeout => 120,
    workers => 1,
};

=head1 RUNNING

C<<< # hypnotoad rss.pl >>>

Now point your browser to the IP address and port your configured.

When you start the application it will automatically create the table spaces and necessary indices.

=head1 PREREQUISITES

=over 1

=item Mojolicious::Lite

=item Mojo::UserAgent

=item Mojo::Log;

=item HTML::FormatText

=item Time::Piece

=item Time::Seconds

=item XML::Feed

=item DateTime

=item DBI

=item DBD::SQLite

=item utf8

=back

=head1 SCRIPT CATEGORIES

Web

=head1 AUTHOR

Mike Plemmons, <mikeplem@cpan.org>

=head1 LICENSE

Copyright (c) 2014, Mike Plemmons
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Mike Plemmons nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL MIKE PLEMMONS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
