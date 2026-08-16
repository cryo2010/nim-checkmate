# README demo

The project behind the example run on checkmate's landing page. Three test
files exercise the three file states checkmate reports:

- `tests/t_config.nim` &mdash; all passing (`PASS`)
- `tests/t_math.nim` &mdash; a failing `check a + b == 5` in a suite (`FAIL`)
- `tests/t_net.nim` &mdash; a deterministically flaky test (`FLAKY`, 8/10)

## Run it

```sh
./run.sh
# or, against a source build:
CHECKMATE=../../checkmate ./run.sh
```

`run.sh` deletes the `net_counter` file first (so the 8/10 flake is
reproducible) and runs `checkmate --color:never --loop:10 --jobs:1`. The
`--jobs:1` keeps the header lines in alphabetical order to match the README;
`--loop:10` drives flake detection.

## Note: the README block is lightly idealized

A single real run cannot match the landing example exactly, because the
`FLAKY` line requires `--loop`, and looping changes the rest of the output:

- the real `FAIL` block gains a `failed in all 10 iterations` line;
- checkmate also prints a detail block for the flaky `t_net` (the README
  shows only the `t_math` block);
- the README's aggregate counts are padded for illustration.

This project reproduces the same shape and the exact `FAIL` detail block;
the differences above are the curated parts.
