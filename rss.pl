#!/usr/bin/perl

use Mojolicious::Lite;
use Mojo::UserAgent;
use HTML::FormatText;
use Time::HiRes qw(usleep);
use XML::Feed;
use DateTime;
use DBI;
use utf8;

$| = 1;

my $debug = 0;

my $now_time = localtime();

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$hour = "0" . $hour if $hour < 10;
$mon  = $mon + 1;
$mon  = "0" . $mon if $mon < 10;
$year = $year + 1900;


# hypnotoad configuration
app->config(
    hypnotoad => {
        listen => ['http://192.168.1.20:90'],
    }
);

my %months = (
    Jan => '00', Feb => '01', Mar => '02',
    Apr => '03', May => '04', Jun => '05',
    Jul => '06', Aug => '07', Sep => '08',
    Oct => '09', Nov => '10', Dec => '11'
);

my $pg_db = "rss_db";
my $user  = "rss_user";
my $pass  = "rss_user";

my $dbh = DBI->connect("dbi:Pg:dbname=$pg_db", "$user", "$pass");
$dbh->{RaiseError}     = 1;
$dbh->{PrintError}     = 0;
$dbh->{pg_enable_utf8} = 1;

# ------------- NEWS HELPER FUNCTIONS -------------

# this provides a way to get to the database in the template
helper db => sub { $dbh };

# create the database
helper create_tables => sub {

    my $self = shift;

	warn "Creating rss tables\n";
	
    $self->db->do(
        'create table if not exists rss_feeds (feed_id serial primary key, feed_name text, feed_url text)'
    );
        
    $self->db->do(
        'create table if not exists rss_news (news_id serial primary key, 
												feed_id serial, 
												news_date text, 
												news_title text, 
												news_desc text, 
												news_url text, 
												news_seen smallint, 
												news_fav smallint)'
    );
    
    $self->db->do('create index rss_feeds_idx on rss_feeds (feed_id)');
    $self->db->do('create index rss_news_idx on rss_news (news_id, feed_id, news_title)');

};

helper select_feeds => sub {
    my $self = shift;

	my $get_feeds = eval {
		
		$self->db->prepare('
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
		')
	
	} || return undef; # end of the eval of the prepare statement
	
	$get_feeds->execute();
	return $get_feeds->fetchall_arrayref;

};

helper select_news => sub {
    my $self = shift;
	my $rss_feed_id = shift;
	
	my $get_news = $self->db->prepare('
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
	return $get_news->fetchall_arrayref;
	
};

helper select_favs => sub {
    my $self = shift;
	
	my $get_favs = $self->db->prepare('
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
	return $get_favs->fetchall_arrayref;
	
};

helper edit_feed_list => sub {
    my $self = shift;
	
	my $get_feeds = $self->db->prepare('
		select
			feed_id, feed_name, feed_url
		from
			rss_feeds
		order by
			feed_name asc
		');
		
    $get_feeds->execute();
	return $get_feeds->fetchall_arrayref;
};


# if the select feeds fails then create the database tables
app->select_feeds || app->create_tables;

# ------------- NEWS ROUTES -------------

# setup base route - DONE
any '/' => sub {
	my $self = shift;
	
	my $rows = $self->select_feeds;
	$self->stash( feed_rows => $rows );
	$self->render('list_feeds');
};

# get the id of the feed to view - DONE
get '/view_news/:feed/:name' => sub {
    my $self = shift;
    my $news_id = $self->param('feed');
    my $news_name = $self->param('name');
    
    my $news_rows = $self->select_news($news_id);
    $self->stash(news_rows => $news_rows);
    $self->stash(news_id => $news_id);
    $self->stash(news_name => $news_name);    
    $self->render('rss');
};

# setup base route - DONE
get '/favs' => sub {
	my $self = shift;
	
	my $rows = $self->select_favs;
	$self->stash( fav_rows => $rows );
	$self->render('favs');
};

# setup base route - DONE
get '/edit_feeds' => sub {
	my $self = shift;
	
	my $rows = $self->edit_feed_list;
	$self->stash( edit_rows => $rows );
	$self->render('edit_feeds');
};

# setup base route - DONE
get '/maint_feeds' => sub {
	my $self = shift;
	
	my $rows = $self->edit_feed_list;
	$self->stash( edit_rows => $rows );
	$self->render('maint');
};


# add feeds to the database - DONE
get '/add_feeds' => sub {
    my $self = shift;
    my $feed_name = $self->param('feed_name');
    my $feed_url  = $self->param('feed_url');
    
    my $insert_feed = $dbh->prepare('insert into rss_feeds (feed_name, feed_url) values (?, ?)');
    $insert_feed->execute($feed_name, $feed_url);
    $insert_feed->finish;
    
    return $self->render(text => 'done', status => 200);
    #$self->render('feeds_added');
};

# update the news feed with the state chosen by
# the button the user hits - DONE
get '/update_news' => sub {
    my $self = shift;
    my $feed_id = $self->param('feed_id');
    my $feed_update = $self->param('feed_type');
    my $update;

    if ( $feed_update eq "seen" ) {
        $update = $dbh->prepare('update rss_news set news_seen = 1 where news_id = ?');
    } elsif ( $feed_update eq "seen_all" ) {
        $update = $dbh->prepare('update rss_news set news_seen = 1 where feed_id = ?');
    } elsif ( $feed_update eq "fav" ) {
        $update = $dbh->prepare('update rss_news set news_fav = 1, news_seen = 1 where news_id = ?');
    } elsif ( $feed_update eq "unfav" ) {
        $update = $dbh->prepare('update rss_news set news_fav = 0 where news_id = ?');
    } else {
        print "an expected news_type was not provided\n";
        return $self->render(text => 'failed news_type', status => 500);
    }
    
    $update->execute($feed_id);
    $update->finish;
    
    return $self->render(text => 'done', status => 200);
    
};

# update the feed status
get '/update_feed' => sub {
    my $self = shift;
    my $feed_id = $self->param('feed_id');
    my $feed_url = $self->param('feed_url');

    my $update = $dbh->prepare('update rss_feeds set feed_url = ? where feed_id = ?');
    
    $update->execute($feed_url, $feed_id);
    $update->finish;
    
    #$self->render('edit_feeds');
    return $self->render(text => 'done', status => 200);
    
};

# delete a feed from the list
get '/delete_feed' => sub {
    my $self = shift;
    my $feed_id = $self->param('feed_id');

    my $delete_feed = $dbh->prepare('delete from rss_feeds where feed_id = ?');
    $delete_feed->execute($feed_id);
    $delete_feed->finish;

    my $delete_news = $dbh->prepare('delete from rss_news where feed_id = ?');
    $delete_news->execute($feed_id);
    $delete_news->finish;
    
    #$self->render('edit_feeds');
    return $self->render(text => 'done', status => 200);
};

# clean up the database
get '/cleanup' => sub {
    my $self = shift;
    my $days_back = $self->param('days_back');

    # the user will provide a number of days to delete older than the current date
    # this SQL statement will find that actual date to use in the delete statement
    # below
    my $sql_days_back = "$days_back day";
    my $prev_day_sql = "select current_date - cast (? as interval)";
    my $get_prev_date = $dbh->prepare($prev_day_sql);
    
    $get_prev_date->execute($sql_days_back);
    my @date_to_remove_arr = $get_prev_date->fetchrow_array();

    my $remove_date = $date_to_remove_arr[0];
    #$get_prev_date->finish;
    
    my $remove_old_news = $dbh->prepare("delete from rss_news where news_date <= ? and news_fav = '0'");
    $remove_old_news->execute($remove_date);
    #$remove_old_news->finish;
    
    return $self->render(text => 'done', status => 200);
};

# add news into the database
# this can also be used as a way to update the news
# due to performance issues we actually only add
# 10 feeds at a time.  the script will call itself
# until all feeds we know about have been updated
get '/add_news' => sub {
    
    my $self = shift;
    my $insert_news;
    
    print "\n---------------------\n" if $debug;
    print "Adding news\n\n" if $debug;
    
    # read in the SQL offset if one exists so we
    # only read 10 feeds at a time.  if no offset
    # is provided then start at 0
    my $offset = $self->param('offset') // 0;
   
    # get the total number of feeds we have so we know when
    # to stop the recursive call to add_news
    my $feed_count = $dbh->prepare("select count(*) from rss_feeds");
    $feed_count->execute();
    my @num_feeds = $feed_count->fetchrow_array();
    $feed_count->finish;
    
    # create the number of feeds to use as a stopping point
    # with the recursive call.  this number is the break
    # out of the loop count
    my $total_feeds = $num_feeds[0];
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

    
    # look through the feeds and get the RSS data
    while ( my @feed_data = $get_feeds->fetchrow_array() ) {
        
        my $rss_id   = $feed_data[0];
        my $rss_name = $feed_data[1];
        my $rss_url  = $feed_data[2];
        
        print "$rss_name - head request\n" if $debug;

        # check that the URL exists by doing a HEAD against the URL
        my $ua = Mojo::UserAgent->new;
        if ( ! defined $ua ) {
            print "\tUA not defined\n" if $debug;
            usleep(250);
            next;
        }

        my $tx = $ua->head($rss_url);
        if ( ! defined $tx ) {
            print "\thead request failed\n" if $debug;
            usleep(250);
            next;
        }
 
        # the URL was not correct as a 200 did not return
        # insert a bad url into the database
        if ( $tx->res->code !~ /200|501/ ) {
            
            $self->clear_prepare();

            # feed_id, news_date, news_title, news_desc, news_url
            $insert_news = $dbh->prepare("insert into rss_news (feed_id,news_date,news_title,news_desc,news_url,news_seen,news_fav) values (?, ?, ?, ?, ?, ?, ?)");
            $insert_news->execute($rss_id, '2099-01-01 00:00:00:000', 'bad url', $rss_url, '', 0, 0);
            
            print "\tskipping\n" if $debug;
            next;
        }

        print "\tAbout to parse the RSS URL - $rss_url\n" if $debug;

        my $feed;
        eval {
            # the URL is good so pull it
            $feed = XML::Feed->parse(URI->new($rss_url));
        };
        
        if ( $@ ) {
            print "There was a problem parsing $rss_url\n";
            next;
        }
            
        if ( ! defined $feed ) {
            print "\tCannot parse $rss_url - $rss_url\n";
            usleep(250);
            next;
        }

        print "\tURL parsed\n" if $debug;

        # look through each item in the RSS feed
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
 
            # if the feed includes a date use it but it not
            # create our own using the current time
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
            
            my $title = $story->title;
            $title    = "Empty title" if ! defined $title;
            
            my $desc  = $story->content->body;
            $desc     = "Empty body" if ! defined $desc;
            
            my $url   = $story->link;
            $url      = $rss_url if ! defined $url;

            # strip HTML tags
            my $desc_string = HTML::FormatText->format_string($desc);
            $desc_string =~ s/\[IMAGE\]//g;
            $desc_string =~ s/\s+$/\n\n/;
            
            print "\tDoes the title exist?\n" if $debug;
            
            my $find = $dbh->prepare("select count(*) from rss_news where news_title = ? and feed_id = ?");
            $find->execute($title, $rss_id);
            my @count = $find->fetchrow_array();
            $find->finish;
            
            # if the article does not exist in the database then add it
            # otherwise skip it
            if ( $count[0] == 0 ) {
                
                print "\tAdd news\n" if $debug;

                my $insert_news = $dbh->prepare("insert into rss_news (feed_id,news_date,news_title,news_desc,news_url,news_seen,news_fav) values (?, ?, ?, ?, ?, 0, 0)");                
                $insert_news->execute($rss_id, $date, $title, $desc_string, $url);
                $insert_news->finish;
            }
            
        } # END foreach my $story ($feed->entries) {
        
    } # END while ( my @feed_data = $get_feeds->fetchrow_array() ) {

    $get_feeds->finish;

    # the recursive call used to keep gathering news
    # until we have gathered all the feeds we have
    if ( $offset >= $total_feeds ) {
        $self->redirect_to('/');        
    } else {
        $self->redirect_to("/add_news?offset=$offset");
    }

};

# when the user wants to add a feed they need to start here
get '/add_feed' => 'add_feed';

app->start;

# ------------- HTML TEMPLATES -------------

__DATA__
@@list_feeds.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>News Feeds</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <style>
            %= include 'rss_style'
        </style>
    </head>
    <body>
		%= include 'header'
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

@@ feeds_added.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>News Feeds Added</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <style>
            %= include 'rss_style'
        </style>
    </head>
    <body>
        Feeds Added
        %= include 'footer'
    </body>
</html>

@@ db_created.html
<!DOCTYPE html>
<html>
    <head>
        <title>News DB Created</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <style>
            %= include 'rss_style'
        </style>
    </head>
    <body>
        Database created or already exists
        %= include 'footer'
    </body>
</html>

@@ header.html.ep
<div style='padding-bottom: 40px;'>
<ul>
<!-- <li><a href="<%=url_for('/add_feed')->to_abs%>">Add</a></li> -->
<li><a href="<%=url_for('/add_news')->to_abs%>">Update</a></li>
<li><a href="<%=url_for('/maint_feeds')->to_abs%>">Manage</a></li>
<!-- <li><a href="<%=url_for('/edit_feeds')->to_abs%>">Edit</a></li> -->
<li><a href="<%=url_for('/')->to_abs%>">View</a></li>
<li><a href="<%=url_for('/favs')->to_abs%>">Favs</a></li>
</ul>
</div>
<div class='clear'></div>

@@ footer.html.ep
<p />
<div class='clear'></div>
<ul>
<li><a href='#top'>Top</a></li>
<!-- <li><a href="<%=url_for('/add_feed')->to_abs%>">Add</a></li> -->
<li><a href="<%=url_for('/add_news')->to_abs%>">Update</a></li>
<li><a href="<%=url_for('/maint_feeds')->to_abs%>">Manage</a></li>
<!-- <li><a href="<%=url_for('/edit_feeds')->to_abs%>">Edit</a></li> -->
<li><a href="<%=url_for('/')->to_abs%>">View</a></li>
<li><a href="<%=url_for('/favs')->to_abs%>">Favs</a></li>
</ul>
<div style='padding-bottom: 40px;'></div>

@@ rss_style.html.ep
@media all and (orientation: portrait) and (max-device-width: 480px) {
    body {
        max-width: 480px;
        font-size: 14px;
        background-color: black;
        color: white;
    }
}

@media all and (orientation: portrait) and (max-device-width: 720px) {
    body {
        max-width: 720px;
        font-size: 14px;
        background-color: black;
        color: white;
   }
}
    
@media all and (orientation: portrait) and (max-device-width: 1280px) {
    body {
        max-width: 1280px;
        font-size: 14px;
        background-color: black;
        color: white;
    }
}
    
@media all and (orientation: landscape) and (max-device-width: 480px) {
    body {
        max-width: 480px;
        font-size: 14px;
        background-color: black;
        color: white;
   }
}
    
@media all and (orientation: landscape) and (max-device-width: 720px) {
    body {
        max-width: 720px;
        font-size: 14px;
        background-color: black;
        color: white;
   }
}

@media all and (orientation: landscape) and (max-device-width: 1280px) {
    body {
        max-width: 1280px;
        font-size: 14px;
        background-color: black;
        color: white;
   }
}

fieldset {
   border-style: none;
   float: left;
}

.news {
    white-space: pre-line;
    /*white-space: pre-wrap;*/
}

.header {
    margin-top: 2em;
    margin-bottom: 2em;
}

.feedlink {
    margin-top: .1em;
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

@@maint.html.ep
<!DOCTYPE html>
<html>
    <head>
        <title>Manage Feeds</title>
        <meta content="width=device-width, initial-scale=1.0, maximum-scale=2.0, user-scalable=yes" name="viewport"></meta>
        <script>
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
                    
                    //alert('name=' + name + ' and url=' + url);
                    
                } else if ( state == 'clean' ) {
                    
                    number = document.getElementById('days_back').value;
                    
                    xmlhttp.open("GET","/cleanup?days_back=" + number, true);
                    xmlhttp.send();
                    
                    //alert('number=' + number);
                    
                } else if ( state == 'update' ) {
                    
                    xmlhttp.open("GET","/update_feed?feed_id=" + arg_one + "&feed_url=" + arg_two, true);
                    xmlhttp.send();

                    //alert('id=' + arg_one + ' and url=' + arg_two);
                    
                } else if ( state == 'delete' ) {
                    
                    xmlhttp.open("GET","/delete_feed?feed_id=" + arg_one, true);
                    xmlhttp.send();
                    
                    //alert('id=' + arg_one);
                    
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
