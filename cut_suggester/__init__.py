"""Reference two-stage LLM cut-suggester + prompt oracle.

From a raw interview transcript, propose product-shaped cut candidates (radio
Intros and Artist Spotlights) as ranked suggestions for a human editor. The LLM
is the segmenter; all validation, span→word-ID mapping, duration (from samples),
dedupe/merge, and ranking are pure, network-free post-processing (`postprocess`,
`stitch`). The network call is a single injectable seam (`llm`, `cache`).

This package is the prompt oracle and reference implementation. Whether
production shells to it or reimplements it in Swift is a later decision; the
boundary is kept clean.
"""
