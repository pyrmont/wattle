# AFL fuzzing scripts

To use these, install afl and xterm. A tiling window manager helps manage many
concurrent fuzzer instances.

AFL sometimes requires system configuration. If AFL quits prematurely, launch
it by hand and address the error messages it prints.

## Fuzz the parser
```
$ sh ./tools/testing/afl/prepare_to_fuzz.sh
$ export NFUZZ=1
$ sh ./tools/testing/afl/fuzz.sh parser
Ctrl+C when done to close all fuzzer terminals.
$ sh ./tools/testing/afl/aggregate_cases.sh parser
$ ls ./fuzz_out/parser_aggregated/
```

## Fuzz the unmarshaller
```
$ janet ./tools/testing/afl/generate_unmarshal_testcases.janet
$ sh ./tools/testing/afl/prepare_to_fuzz.sh
$ export NFUZZ=1
$ sh ./tools/testing/afl/fuzz.sh unmarshal
Ctrl+C when done to close all fuzzer terminals.
$ sh ./tools/testing/afl/aggregate_cases.sh unmarshal
$ ls ./fuzz_out/unmarshal_aggregated/
```
