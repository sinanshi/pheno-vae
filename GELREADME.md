# GEL project template

A starting point for a new analysis on the Genomics England (GEL) research
environment: code is written and tested here, and moved to GEL by copy-paste of
one text file. Data never leaves GEL and never travels in a bundle.

## Start a new project

```bash
./new_project.sh ~/Desktop/myproject      # copies this template, names the project
cd ~/Desktop/myproject
Rscript tools/make_mock.R                 # mock inputs under data/, for local runs
```

Then replace the example (`pipeline/scripts/*.R`, the processes in
`pipeline/main.nf`, `pipeline/config/config.yaml`, `data_structure.txt`) with the
real analysis.

## Moving code to GEL: the only file is `bundle.txt`

```bash
./bundle.sh pack          # local: source tree -> bundle.txt, also copied to the clipboard
```

On GEL, open an editor in the project folder, paste, save as `bundle.txt`, then:

```bash
bash bundle.txt           # first time: the bundle is self-extracting and installs bundle.sh
./bundle.sh populate      # every later time
```

- **What travels:** source files only (`.R .sh .py .nf .yaml .config .md .txt ...`
  under 1 MB). Data extensions (`.csv .tsv .rds .vcf .bed .pgen .pdf ...`) never
  pack and are refused when populating, so a bundle cannot overwrite data.
- **Never touched:** `data/`, `work/`, `nf_work/`, `logs/`, `results/` (see
  `.bundle.conf`). Keep data in `data/` or point `config.yaml` at absolute paths.
- **Checksums:** every file is checked, unchanged files are not rewritten (so
  Nextflow's resume is not disturbed), anything replaced is backed up in
  `.bundle_backup/`, and `.bundle_applied` records which bundle is in place
  (Nextflow prints it at the start of each run).
- **Deleted a file locally?** `./bundle.sh populate --prune` removes it on GEL too
  (backed up first).
- **Check the data first:** `./bundle.sh check` compares the real files against
  `data_structure.txt` -- delimiter, header, columns. Most bugs are a data-shape
  mismatch; this catches them in seconds.

## Running on GEL

From `pipeline/`, with Nextflow loaded and Rscript on PATH:

```bash
nextflow run main.nf                 # light steps on this node, heavy steps as LSF jobs
nextflow run main.nf --prep_only     # stop after preparation; check work/logs/ first
nextflow run main.nf -profile lsf    # every step as an LSF job
```

Nextflow must stay alive for the whole run (it submits and follows the jobs):
use tmux / screen, or submit Nextflow itself to the interactive queue:

```bash
bsub -P re_gecip_machine_learning -q inter -n 4 -M 40000 -R "span[hosts=1] rusage[mem=40000]" \
     -J nf_head -o logs/nf_head.%J.out -e logs/nf_head.%J.err nextflow run main.nf
```

Every run resumes: a finished step is reused unless its inputs, settings or R
script changed. Outputs are under `pipeline/work/`; `nf_work/` is Nextflow's
scratch (safe to delete when done, at the cost of resuming);
`logs/nextflow/trace.txt` has one line per job. To rerun one step's command by
hand, it is in `.command.sh` of that task's `nf_work/` folder.

## Layout

```
.
├── bundle.sh, .bundle.conf      transfer; what packs and what never does
├── data_structure.txt           expected shape of every input (./bundle.sh check)
├── new_project.sh               copy this template into a new project
├── tools/make_mock.R            mock inputs under data/ for local runs
├── analysis/                    standalone scripts, run by hand after the pipeline
└── pipeline/
    ├── main.nf                  orchestration only; reads config/config.yaml
    ├── nextflow.config          where steps run (labels light / heavy), resume, trace
    ├── config/config.yaml       every path, column name, parameter and resource
    ├── R/lib.R                  shared helpers (arguments, logging, column checks)
    └── scripts/*.R              one standalone script per step, key=value arguments
```

Adding a step: write `scripts/<step>.R`, add a `process` to `main.nf` (copy one,
with label `light` or `heavy`), add the step name to `STEPS` in `main.nf`, and,
if it needs more than the default, a line under `resources:` in `config.yaml`.

## GEL notes (learned the hard way)

- **No internet.** Nothing can be downloaded at run time.
  - Nextflow: `module load` the installed version (23, 24 and 25 exist); do not
    set `NXF_VER` (that makes it try to download a jar); `export NXF_OFFLINE=true`.
  - Python packages: GEL's mirror,
    `pip install --index-url https://artifactory.aws.gel.ac/artifactory/api/pypi/pypi/simple <pkg>`.
  - R: tidyverse is not available; data.table and Matrix are. `lib.R` adds GEL's
    shared library `/tools/aws-workspace-apps/ce/R/4.0.2` to the search path.
- **LSF.** Queues `short` (4 h) and `medium` (24 h) for jobs, `inter` for a
  Nextflow head job; project `-P re_gecip_machine_learning` (change it in
  `config.yaml` for another GECIP). Nextflow's LSF executor already adds
  `-R "span[hosts=1]"` for multi-thread jobs; a second span in
  `clusterOptions` makes LSF reject the job ("multiple -R resource requirement
  strings are not supported on span").
- **Nextflow quirks.** A `process` block can read variables but cannot call
  functions (every call is taken as a directive): work values out beforehand,
  as `RES` in `main.nf` does. Closures inside `workflow {}` need `def` and are
  called with `.call(...)`. Local steps also obey their `time` limit.
- **Identifiers.** GEL has two ID spaces: participant ID (clinical tables:
  ICD-10, HPO, rare disease / cancer tables) and plate key (genomes: aggV2,
  VCFs, most per-sample pipeline outputs). Rare-disease pairs are in
  `rare_disease_analysis` (`Participant_Id`, `Plate_Key`). Check which one each
  file uses before joining, and report how many rows match.
- **Useful aggV2 resources** (under
  `/gel_data_resources/main_programme/aggregation/aggregate_gVCF_strelka/aggV2/additional_data/`):
  `HQ_SNPs/MAF1/GELautosomes_LD_pruned_1kgp3Intersect_maf0.01_mpv10` (PLINK bed,
  127,747 LD-pruned SNPs, e.g. REGENIE step 1) and
  `PCs_relatedness/relatedness/GEL_aggV2_MAF5_mp10_0.0442.kin0` (KING pairs).
- **data.table:** never name a column `key` inside `data.table(...)`: it is
  taken as the `key` argument and fails with "some columns are not in the
  data.table".
