# docs

- [`reference/`](reference/): how the repository works. [`architecture.md`](reference/architecture.md)
  covers the three layers, the seams a private layer plugs into, what an apply does, what lands
  where, the checks and how a change reaches every machine. The diagram is in two variants,
  `architecture-light.svg` and `architecture-dark.svg`, drawn from one layout.
  [`fleet-manifest.md`](reference/fleet-manifest.md) is the schema of `~/Devel/mani.yaml`: every key,
  what reads it, what is required, and how to validate it.
