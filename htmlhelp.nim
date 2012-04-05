import htmlgen, strtabs, strutils
type
  THtmlTable* = object
    rows: seq[TRow]

  TRow*    = seq[PColumn]
  PColumn* = ref TColumn
  TColumn* = tuple[header: bool, attrs: PStringTable, text: string]

proc initTable*(): THtmlTable =
  result.rows = @[]

proc addRow*(table: var THtmlTable, count = 1) =
  ## Adds `count` many rows to `table`.
  for i in 0..count-1:
    table.rows.add(@[])

proc addCol*(row: var TRow, text: string, isHeader = false,
             attrs: seq[tuple[name, content: string]] = @[]) =
  ## Adds column with the name of `text` to `row`.
  var c: PColumn
  new(c)
  c.header = isHeader
  c.attrs = newStringTable(modeCaseInsensitive)
  for key, val in items(attrs):
    c.attrs[key] = val
  c.text = text
  row.add(c)

proc insertCol*(row: var TRow, i: int, text: string, isHeader = false,
             attrs: seq[tuple[name, content: string]] = @[]) =
  ## Inserts column with the name of `text` to `row` at index `i`.
  var c: PColumn
  new(c)
  c.header = isHeader
  c.attrs = newStringTable(modeCaseInsensitive)
  for key, val in items(attrs):
    c.attrs[key] = val
  c.text = text

  row.insert(c, i)

proc `[]`*(table: var THtmlTable, i: int): var TRow =
  ## Retrieves row at `i`
  return table.rows[i]

proc findCols*(row: var TRow, text: string): seq[PColumn] =
  ## Finds and returns columns with the name of `text`.
  result = @[]
  for c in row:
    if c.text == text:
      result.add(c)

proc contains*(row: var TRow, text: string): bool =
  ## Returns whether `row` contains column by the name of `text`.
  result = false
  for c in row:
    if c.text == text:
      return true

iterator items*(table: THtmlTable): TRow =
  var i = 0
  while i < table.rows.len:
    yield table.rows[i]
    i.inc()

iterator items*(row: TRow): PColumn =
  var i = 0
  while i < row.len:
    yield row[i]
    i.inc()

proc len*(table: var THtmlTable): int =
  ## Returns the number of rows.
  return table.rows.len()

proc len*(row: TRow): int =
  ## Returns the number of columns in a row.
  return system.len(row)
  # Solely because using only `len` would cause a recursive loop.

proc toPretty(table: THtmlTable): string =
  # Returns an ASCII representation of the table.
  # TODO: Make this nicer, or just get rid of it.
  result = ""
  for cols in table.rows:
    result.add("| ")
    for i in cols:
      result.add(i.text & " | ")
    result.add("\n----------------------------\n")

proc toHtml*(table: THtmlTable, attrs=""): string =
  result = ""
  var htmlRows: string = ""
  for row in table.rows:
    var htmlCols = ""
    for col in row:
      var htmlAttrs = ""
      for name, text in col.attrs:
        htmlAttrs.add(" " & name & "=\"" & text & "\"")
      
      if col.header:
        htmlCols.add("\n<th$1>$2</th>\n" % [htmlAttrs, col.text])
      else:
        htmlCols.add("\n<td$1>$2</td>\n" % [htmlAttrs, col.text])
    htmlRows.add(tr(htmlCols) & "\n")
  
  result = "<table $1>\n" % [attrs] & htmlRows & "</table>"

when isMainModule:
  var tab = initTable()
  tab.addRow()
  tab.addRow()
  tab[0].addCol("Col 1", true, @[("class", "something"), ("blah", "something")])
  tab[0].addCol("Col 2", true)
  tab[2].addCol("Hello")
  tab[2].addCol("I SHOULD BE IN FUCKING SCHOOL")
  tab[2].addCol("With rachel.")
  tab[2].addCol("And be kissing her.")
  echo tab.toPretty
  
  echo(" ")
  for r in tab:
    for c in r:
      echo(c.text)
    echo("----")
  
  echo tab.toHtml()
  