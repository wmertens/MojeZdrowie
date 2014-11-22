Q = require 'q'
FS = require 'q-io/fs'
HTTP = require 'q-io/http'
Apps = require 'q-io/http-apps'
log4js = require 'log4js'
htmlParser = require 'htmlparser2'

conf =
  # Used manual binary search to find current maximum
  # maxNum = 29056
  # Use less for testing
  maxNum: 200
  logLevel: 'DEBUG'
  placeHTMLDir: "placesHTML"
  placeURL: "https://rpwdl.csioz.gov.pl/rpm/druk/wyswietlKsiegaServlet?idKsiega="
  geoURL: "http://nominatim.openstreetmap.org/search?format=jsonv2&countrycodes=pl&limit=1&q="

conf.placesCache = FS.join(conf.placeHTMLDir, "places.json")

getLogger = (what) ->
  logger = log4js.getLogger(what)
  logger.setLevel conf.logLevel
  return logger

logger = getLogger("main")
# Handy functions to pass to .next() as-is
dump = (o) -> logger.debug o; o
dumpAndDie = (o) -> logger.error o; throw o


# Queue a function for later execution returning a promise for its result.
# Only a predefined number of tasks are run simultaneously, the rest is queued.
class promisQueue
  async = require 'async'

  # Run a queued task by resolving its starting promise with the async callback
  resolver = (deferred, finished) -> deferred.resolve(finished)

  # num is the max number of concurrent tasks
  constructor: (num) ->
    @tasks = async.queue resolver, num or 5
    @doneP = null

  # Queue a function to call by attaching it to a new promise
  # Returns the promise for its result (which can be a promise too)
  queue: (task) ->
    deferred = Q.defer()
    # Run the function when starting promise resolves
    promise = deferred.promise.then (cb) -> Q.fcall(task).finally(cb)
    @tasks.push deferred
    return promise

  # Return a promise for when all tasks in the queue are done
  done: ->
    unless @doneP
      deferred = Q.defer()

      if @tasks.idle()
        deferred.resolve()
        return deferred.promise

      @tasks.drain = =>
        @doneP = null
        @tasks.drain = null
        deferred.resolve()

      @doneP = deferred.promise

    return @doneP

# All the entities. Sparse array indexed by the registry's id.
places = []

# Download an entity and cache the result
getPlaceHTML = (id) ->
  file = FS.join conf.placeHTMLDir, "#{id}.html"

  return Q()
  .then(-> FS.exists(file))
  .then( (exists) ->
    if exists
      return FS.read(file)

    else
      url = conf.placeURL + id

      return Q()
      .then(->
        logger.debug "Requesting #{url}"

        return HTTP.read(url)
      )
      .then((body) ->
        logger.debug "Storing #{file}"
  
        return FS.write(file, body)
        .then(-> body.toString())
      )
  )

# Parse the HTML
parsePlace = (html) ->
  # Not sure if htmlparser2 is async, no time to find out
  deferred = Q.defer()
  state = 0
  inTd = 0
  tdText = ""
  address = ""
  place = {}
  parser = {
    ontext: (text) ->
      if inTd
        # To be really correct this should be a stack for embedded tables
        tdText += text
        .replace(/&nbsp;/g, " ")
        .replace(/&oacute;/g, "ó")
        .replace(/&Oacute;/g, "Ó")
        .replace("Brak wpisu", "")
        .trim()

    onopentagname: (name) ->
      if name is "td"
        inTd += 1
        tdText = ""
    onclosetag: (name) ->
      if name is "td"
        inTd -= 1
        # Once we leave a td we have all the internal text
        # State machine to get results we want
        switch state
          when 0
            if tdText.substr(0, 10) is "Rubryka 3."
              state = 1
          when 1
            place.title = tdText
            state = 2
          when 2
            if tdText.substr(0, 8) is "1. Ulica"
              state = 3
          when 3
            address = tdText
            .replace(/ulica /i, "")
            .replace(/ul\. /i, "")
            .replace(/plac /i, "")
            state = 4
          when 4
            if tdText.substr(0, 2) is "2."
              state = 5
          when 5
            address += " " + tdText if tdText
            state = 6
          when 6
            if tdText.substr(0, 2) is "3."
              state = 7
          when 7
            address += "/" + tdText if tdText
            state = 8
          when 8
            if tdText.substr(0, 2) is "4."
              state = 9
          when 9
            address += ", " + tdText if tdText
            state = 10
          when 10
            if tdText.substr(0, 2) is "5."
              state = 11
          when 11
            address += " " + tdText if tdText
            place.address = address if address
            state = 12
          when 12
            if tdText.substr(0, 10) is "Rubryka 5."
              state = 13
          when 13
            place.phone = tdText if tdText
            p.reset()
            state = 14


    onerror: (err) -> logger.error err
    onend: ->
      deferred.resolve(if place.address then place else null)
  }
  p = (new htmlParser.Parser(parser))
  p.write(html)
  p.end()

  return deferred.promise

# Get geo lookup from OpenStreetMaps
getGeo = (address) ->
  url = conf.geoURL + encodeURIComponent address

  return HTTP.read(url)
  .then(JSON.parse)
  .then((o) ->
    if o?[0]
      return {
        lat: o[0].lat
        long: o[0].lon
      }
    else
      throw "No results"
  )
  .fail((err) ->
    logger.warn "Lookup failed for #{address} (#{err})"
  )

callQueue = new promisQueue
getAllPlaces = ->
  queueId = (id) ->
    return if places[id]
    callQueue.queue ->
      getPlaceHTML(id)
      .then(parsePlace)
      .then((data) ->
        logger.info "Done parsing #{id}"

        if data
          return getGeo(data.address)
          .then((coords)->
            if coords
              data.id = id
              data.lat = coords.lat
              data.long = coords.long
              places[id] = data
          )
      )
      .fail((err) ->
        logger.error "Couldn't get/parse #{id}: #{e}"
      )

  for i in [1 .. conf.maxNum]
    queueId i

  logger.info "Queued all requests"
  return callQueue.done().then(-> places)


savePlaces = (places) ->
  logger.info "Saving found places to cache"
  return FS.write(conf.placesCache, JSON.stringify(places))
  .then(->places)

loadPlaces = ->
  return FS.read(conf.placesCache)
  .then(JSON.parse)
  .then((p) -> places = p)
  .fail((e) -> logger.error "Couldn't load places cache (#{e}), continuing")

Q()
.then(->
  return FS.makeDirectory(conf.placeHTMLDir)
  .fail((e) -> throw e if e.code isnt "EEXIST")
)
.then(loadPlaces)
.then(getAllPlaces)
.then(savePlaces)
.then(->
  results = (place for place in places when place)

  HTTP.Server( (request) ->
    return Apps.json(results)
  )
  .listen(8888)
)
.then( (server) ->
  address = server.address()
  host = address.address
  if host is "0.0.0.0"
    host = "localhost"
  url = "http://#{host}:#{address.port}/"
  HTTP.read(url).then((o)->logger.debug o.toString()).fail((e)->logger.error e)
  logger.info "Server started on #{url}"
)
.fail(dumpAndDie)
