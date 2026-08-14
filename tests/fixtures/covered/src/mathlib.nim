proc double*(x: int): int =
  x * 2

proc sign*(x: int): int =
  if x > 0:
    1
  elif x < 0:
    -1
  else:
    0

proc neverCalled*(x: int): int =
  x + 100
