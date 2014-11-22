MojeZdrowie Server
==================

This is a screen scraper for the
[Polish registry of medical entities](https://rpwdl.csioz.gov.pl/rpm/public/filtrKsiag.jsf).
It extracts the name, address and phone number and does a geo lookup so it
can provide longitude and latitude.

MojeZdrowie is also an Android application that stores this information for offline use,
so you can find the closest entities even without internet.

There doesn't seem to be a nice way to get the list of entities. The search interface shows
results 10 results at a time in a widget that uses AJAX to get pre-rendered lines from the server.
There is lots of XML abuse and slowness.

I resorted to doing brute-force downloads of the detail views, since they are indexed by an integer
with few gaps.

How to install
--------------
You need NodeJS. Clone the repo, run `npm install` and `./node_modules/bin/coffee nazdrowie.coffee`.

Method
------
The details are downloaded and stored as-is in files. Then they are parsed and geolocated.
Successful results are kept and cached. Then a simple server returns the results as a JSON array.

Technologies used
-----------------
- [NodeJS](http://nodejs.org/): server-side JavaScript
- [CoffeeScript](http://coffeescript.org): The proper way to write JavaScript :-)
- [Q-IO and Q](https://github.com/kriskowal/q-io): promises framework, including filesystem interaction
  and HTTP client/server tasks.
- [asyncjs](https://www.npmjs.org/package/async): For the 5-at-a-time processing queue
- [log4js](https://www.npmjs.org/package/log4js): Logging framework
- [OpenStreetMap Nominatim](http://wiki.openstreetmap.org/wiki/Nominatim): Geographic lookup of addresses

Possible improvements
---------------------
- Nominatim doesn't find an address with number if it doesn't have number info for a street. Try
  again without the number. Google Maps has a limit on free requests and the results can only be used
  for Google Maps lookups (licensing terms).
- Extract the type of entity so users can search for the nearest pharmacy or emergency room
- Parse the full entity html into an object instead of scraping the first address out of it
  - Each table row is either a section start, explanation or object attribute
  - There are some embedded tables too
  - Sometimes entities have the useful address in one of the other sections
