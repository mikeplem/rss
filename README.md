# README

This is a web based RSS news aggregator designed for a single user.  It uses Mojolicious as a web framework and PostgreSQL or SQLite as its database.  The interface is mobile friendly.  It does not require any extra web server as it can be used with Mojolicious' hypnotoad web server.  I currently run this script under Arch Linux on an ARM processor but there should be no problems with running it on other Perl platforms.

I used Google Reader quite a bit but when they closed it down I decided to write my own version.  This is the result of that desire.  I specifically wrote it for me and have not put any multi-user capability into the script.

When you first run the application it will create the necessary tables and their indexes if they do not exist.
