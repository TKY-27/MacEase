# 48. Prioritize compression latency within accepted memory

Date: 2026-11-02
Status: Accepted

## Context

Signed candidate 6 compressed the 48 MP photograph to 9,709,855 bytes in
28.1 seconds, retaining the previous output bytes and source hash. Its actual
resident peak was 1,567,784,960 bytes, above the initial 1.5 GB threshold.
The owner accepted memory around 1.56 GB and requested completion in a few
seconds, comparable to their experience with image-compression websites.

## Decision

Accept the observed candidate-6 resident peak within the owner's stated
approximate tolerance. Do not continue work solely to cross 1.5 GB or infer
permission for arbitrary memory growth. Keep the explicit working budget.
Prioritize latency and compare equivalent input, format, resolution, target
size and quality when evaluating other tools. The previous ten/thirty-second
thresholds alone no longer establish the requested user experience.

The earlier quality preference remains in force. Investigate permissively
licensed implementations and measure faster strategies before proposing any
quality tradeoff. Experimental strategy benchmarks do not change production
behavior or constitute acceptance. Do not publish while the requested speed
remains unresolved.

The owner also clarified that VoiceOver remains outside scope in future work.
This extends ADR 0047; retain existing native labels and keyboard behavior,
without claiming VoiceOver support or running further speech verification.

## Consequences

Record the 1.5 GB miss as historical evidence and the subsequent owner
acceptance separately. Do not report a few-second result until completed
outputs demonstrate it. Any proposed speed/quality policy must state measured
benefits and differences for the owner to assess.
