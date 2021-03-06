Handlebars.registerHelper name, fn for name, fn of {
  'debugger' : (optionalValue) ->
    console.log('this', this, 'arguments', arguments)
    debugger
    
  t : (key, defaultValue, options) ->
    wrappers = {}
    options = options?.hash ? {}
    for key, value of options when key.match(/^w\d+$/)
      wrappers[new Array(parseInt(key.replace('w', '')) + 2).join('*')] = value
      delete options[key]
    options.wrapper = wrappers if wrappers['*']
    options = $.extend(options, this) unless this instanceof String or typeof this is 'string'
    I18n.scoped(options.scope).t(key, defaultValue, options)

  hiddenIf : (condition) -> " display:none; " if condition

  hiddenUnless : (condition) -> " display:none; " unless condition
  
  friendlyDatetime : (datetime) ->
    datetime = new Date(datetime) 
    new Handlebars.SafeString "<time title='#{datetime}' datetime='#{datetime.toISOString()}'>#{$.friendlyDatetime(datetime)}</time>"
  
  datetimeFormatted : (isoString) -> 
    isoString = $.parseFromISO(isoString) unless isoString.datetime
    isoString.datetime_formatted
    
  mimeClass: (contentType) -> $.mimeClass(contentType)
  
  newlinesToBreak : (string) ->
    new Handlebars.SafeString $.htmlEscape(string).replace(/\n/g, "<br />")
}
