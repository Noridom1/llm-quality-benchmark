# Quality Benchmark Recipes

Use this sheet to choose and report an eight-benchmark quality run. Counts are fixed, representative samples; `full` means the complete official split. Estimates are initial planning ranges and should be replaced with measured model/endpoint rates.

## Categories

| Category | Benchmarks |
| --- | --- |
| General knowledge | GPQA, MMLU-Pro, HLE |
| Coding | LiveCodeBench, SciCode |
| Agentic coding | BFCL, SWE-bench Pro, DeepSWE |

## Tiers

| Tier | Use | General: GPQA / MMLU-Pro / HLE | Coding: LCB / SciCode | Agentic: BFCL / SWE-Pro / DeepSWE |
| --- | --- | --- | --- | --- |
| Smoke | Wiring and artifact validation | 2 / 2 / 2 | 2 / 2 | 4 / 1 / 1 |
| Balanced | Routine comparison and regression tracking | 50 / 100 / 50 | 50 / 8 | 100 / 10 / 10 |
| Extended | Release candidate and high-confidence comparison | full / 500 / 250 | 200 / 30 | 500 / 50 / 50 |
| Full | Announcement or official competition | full / full / full | full / full | full / full / full |

Use deterministic, stratified manifests for Balanced and Extended; do not use the first N rows. Smoke validates execution only and must not be presented as a quality score.

## Concurrency and planning time

Run benchmarks as separate parallel jobs. A category's wall time is approximately its slowest benchmark, not the sum. Start with these per-benchmark concurrencies:

| Tier | General | Coding | Agentic | Endpoint-wide cap | Expected category wall time |
| --- | --- | --- | --- | --- | --- |
| Smoke | 2-4 | LCB 2-4, SciCode 2 | BFCL 2, SWE/DeepSWE 1 | 8 | General 5-15m; Coding 30-45m; Agentic 30-60m |
| Balanced | GPQA/MMLU 8, HLE 4 | LCB 8, SciCode 4 | BFCL 8, SWE/DeepSWE 2 | 16 | General 1.5-3h; Coding 1-2.5h; Agentic 2.5-6h |
| Extended | GPQA/MMLU 8, HLE 6 | LCB 8-12, SciCode 4-6 | BFCL 12, SWE/DeepSWE 4 | 24 | General 6-12h; Coding 4-8h; Agentic 8-18h |
| Full | 8-16 | LCB 12-16, SciCode 6-8 | BFCL 16, SWE/DeepSWE 4-8 | 32 after load test | 12h to several days |

Concurrency improves throughput only until endpoint saturation. Agent steps within one SWE/DeepSWE task remain sequential. Record p50/p95 latency, tokens, retries, and valid samples/hour so future estimates use observed throughput.

## Main benchmark (default going forward)

Vetted subset+config from the `glm5.2-selfhost-extended` run (model z-ai/glm-5.2 self-host, 2026-09-09/10), reused verbatim for `glm5.3-w4afp8` (2026-09-11/13) so the two campaigns would be comparable. Use this as the standard "main benchmark" for future models instead of re-deriving a manifest per run — it is close to the Extended tier but with each benchmark's subset/CCU tuned from what actually ran clean. Full reports: `jobs/glm5.2-selfhost-extended/README.md`, `jobs/glm5.3-w4afp8/README.md`.

**Launch it with `scripts/run_main_benchmark.sh`** — it encodes every setting in the table/commands below (same subsets, CCU, `MAX_GEN_TOKENS=65536` across all 8 benchmarks) as one script, so a new model's campaign doesn't drift from what actually ran clean here. The per-benchmark commands further down are kept as a reference for what the script does and as a fallback if you need to run/rerun one benchmark by hand.

```bash
RUN_ID=<run-id> bash scripts/run_main_benchmark.sh                  # all 8, sequential by category
RUN_ID=<run-id> bash scripts/run_main_benchmark.sh general coding   # just those categories
```

See the script's header comment for parallel-category launch (one tmux pane per category), why it doesn't pipe stdout through `tee`, and the infra-vs-model failure rerun policy.

| Benchmark | Subset used | CCU | Measured wall clock | Note |
| --- | --- | --- | --- | --- |
| GPQA Diamond | full 198 câu, 5-shot CoT | 8 | ~58m | ổn định, dùng lại nguyên |
| MMLU-Pro | 36 câu/subject (504/~11,000), 14 subject | 8 | ~37m | subsample do giới hạn chi phí, không đại diện đủ từng subject nhỏ |
| HLE | 250/2,500 câu (tier Extended, text-only) | 6 (generate) / 6 (judge) | ~4h49m generate + ~5m judge | chấm bằng LLM-judge (deepseek-v4-pro), không dùng string-match thô — xem [[HLE note]] |
| LiveCodeBench | scenario codegeneration, 199 bài, pass@1 (n=1, temp 0) | 4 | không log được (chỉ có mốc kết thúc) | nên thêm log start time ở lần chạy sau |
| SciCode | split without_background, 30 bài | 8 | ~1h58m | chấm cả sub-step lẫn full-problem, chênh lệch lớn là bình thường |
| BFCL v4 | đủ 13/13 category single-turn (7 non-live + 6 live), không multi-turn/agentic | 4 (mặc định script) | ~37m | có thể tăng CCU (script default thấp, chưa test giới hạn) |
| SWE-bench Pro | full 200 instance | 4 (agent) / 4 (eval) | ~11h36m | benchmark dài nhất, chiếm phần lớn tổng wall clock |
| DeepSWE | full 64 task | **8** (không dùng 16) | ~5h30m khi chạy tuần tự ở CCU8 | CCU 16 làm hết network pool Docker và fail ~1/3 trial (xem [[deepswe-ccu-docker-network-limit]]) — chốt CCU 8 cho lần chạy sau, đừng lặp lại lỗi này |

**Tổng wall clock nếu chạy song song theo category** (như khuyến nghị ở trên): General (GPQA/MMLU-Pro/HLE) ~4h49m (do HLE kéo dài nhất), Coding (LCB/SciCode) ~1h58m, Agentic (BFCL/SWE-Pro/DeepSWE) ~11h36m (do SWE-bench Pro kéo dài nhất) — tổng 3 category chạy song song ~11h36m nếu đủ endpoint capacity cho cả 3 cùng lúc, hoặc cộng dồn ~18h nếu chạy tuần tự từng category.

### Lệnh chạy từng benchmark

Chạy từ `/home/stackops/benchmark`, đã `source .env` (`OPENAI_BASE_URL`, `API_KEY`). Đổi `RUN_ID`/model theo model đang test. Các lệnh đánh dấu **(reconstructed)** là suy ra từ script + config đã ghi nhận (`results_*.json`/`config.json`), không có job.log ghi lại lệnh gốc thật — verify lại flag trước khi dùng cho model mới; lệnh **(confirmed)** là lấy nguyên văn từ job.log.

```bash
# GPQA Diamond — full 198 câu, CCU 8 (reconstructed)
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 \
  bash scripts/run_gpqa.sh

# MMLU-Pro — 36 câu/subject (504 tổng), CCU 8 (reconstructed)
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 LIMIT=36 \
  bash scripts/run_mmlu_pro.sh

# HLE — 250/2,500 câu (125/subtask x 2), CCU 6, generate + judge tự động (reconstructed cho phần generate,
# confirmed cho lệnh judge riêng trong JUDGE.md)
RUN_ID=<run-id> NUM_CONCURRENT=6 MAX_GEN_TOKS=65536 LIMIT=125 REQUEST_TIMEOUT=3600 \
  bash scripts/run_hle.sh
# nếu cần chạy judge riêng (đã có generation từ trước):
RUN_ID=<run-id> ./scripts/judge_hle.sh                                # judge chính: deepseek/deepseek-v4-pro
RUN_ID=<run-id> JUDGE_MODEL=qwen/qwen3.7-plus ./scripts/judge_hle.sh   # judge chéo kiểm chứng
RUN_ID=<run-id> JUDGE_MODEL=<model đang test> ./scripts/judge_hle.sh   # self-judge kiểm tra bias

# LiveCodeBench — scenario codegeneration, LIMIT=200 (kết quả n=199 do 1 bài bị loại), MULTIPROCESS=8
# (confirmed từ tmux scrollback, sweep 2026-09-10 — trước ghi nhầm là chưa xác nhận CCU)
RUN_ID=<run-id> LIMIT=200 MULTIPROCESS=8 \
  bash scripts/run_livecodebench.sh

# SciCode — split without_background, 30 bài, CCU 8, SAMPLE_SHUFFLE=42 (cố định seed để manifest tái lập được)
# (confirmed từ tmux scrollback, sweep 2026-09-10 — trước thiếu SAMPLE_SHUFFLE/MAX_GEN_TOKENS)
RUN_ID=<run-id> LIMIT=30 MAX_CONNECTIONS=8 SAMPLE_SHUFFLE=42 MAX_GEN_TOKENS=65536 \
  bash scripts/run_scicode.sh

# BFCL v4 — đủ 13/13 category single-turn, CCU 4 (reconstructed, chưa xác nhận được TEST_CATEGORY/NUM_THREADS
# thật sự dùng — tmux history-limit 2000 dòng đã làm trôi mất lệnh gốc của lần chạy glm5.2-selfhost-extended,
# kiểm tra lại category_mapping.py trước khi chạy cho model mới)
RUN_ID=<run-id> TEST_CATEGORY=single_turn \
  bash scripts/run_bfcl.sh

# SWE-bench Pro — 200 instance đầu (LIMIT=200, full là 731), CCU 4 agent / 4 eval (reconstructed từ
# run_config.yaml + README — lệnh gốc cũng đã trôi khỏi tmux history do log quá dài, xem note BFCL ở trên)
RUN_ID=<run-id> WORKERS=4 EVAL_WORKERS=4 LIMIT=200 \
  bash scripts/run_swebench_pro.sh

# DeepSWE — full 64 task, gộp từ 3 batch chạy tuần tự (KHÔNG phải 1 lệnh "64 8" duy nhất — đã sửa sau khi
# sweep tmux, doc cũ ghi sai). Batch 1 dùng run_deepswe.sh (N task đầu theo thứ tự mặc định), batch 2/3 dùng
# run_deepswe_tasks.sh với danh sách task cụ thể để rerun đúng phần lỗi. Cả 3 dòng dưới đều (confirmed từ
# tmux scrollback session deepswe-maas).
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 \
  bash scripts/run_deepswe.sh 32 8                                          # batch 1: 32 task đầu, CCU 8
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 JOB_NAME=tasks33-64-ccu16 \
  bash scripts/run_deepswe_tasks.sh deepswe_tasks_33_64.txt 16              # batch 2: task 33-64, CCU 16 — 10/32 lỗi network pool
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 JOB_NAME=rerun10-ccu8 \
  bash scripts/run_deepswe_tasks.sh deepswe_tasks_rerun10.txt 8            # batch 3: rerun đúng 10 task lỗi ở CCU 8
# Khuyến nghị cho lần chạy sau: bỏ qua batch CCU16 nửa chừng, chạy thẳng CCU 8 cho toàn bộ 64 task ngay từ đầu
# (xem [[deepswe-ccu-docker-network-limit]]) — 3-batch ở trên là lịch sử thật đã chạy, không phải cách nên lặp lại.
```

### Lệnh chạy theo category (tuần tự trong mỗi category, fail cái trước không chặn cái sau)

Mỗi category chạy các benchmark bên trong **tuần tự**, nối bằng **`;`** thay vì `&&` — benchmark sau vẫn chạy kể cả khi benchmark trước fail (exit ≠ 0). Lý do đổi: ngày 2026-09-11 GPQA crash giữa chừng (endpoint cắt SSE stream ~15 phút → TransferEncodingError hết retry) làm chết toàn bộ chain `&&`, MMLU-Pro/HLE không hề được chạy. Vì vậy sau khi chạy xong phải tự check riêng output từng benchmark trong `jobs/<run-id>/` — chuỗi `;` không còn báo fail tổng. Lưu ý: `;` chỉ chống lại *fail*; Ctrl+C giữa chừng vẫn dừng cả chuỗi như thường. 3 category có thể chạy song song với nhau nếu endpoint đủ tải (xem bảng CCU/cap ở trên).

```bash
# ── Category: General knowledge (GPQA -> MMLU-Pro -> HLE) ──
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 \
  bash scripts/run_gpqa.sh ; \
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 LIMIT=36 \
  bash scripts/run_mmlu_pro.sh ; \
RUN_ID=<run-id> NUM_CONCURRENT=6 MAX_GEN_TOKS=65536 LIMIT=125 REQUEST_TIMEOUT=3600 \
  bash scripts/run_hle.sh

# ── Category: Coding (LiveCodeBench -> SciCode) ──
RUN_ID=<run-id> LIMIT=200 MULTIPROCESS=8 \
  bash scripts/run_livecodebench.sh ; \
RUN_ID=<run-id> LIMIT=30 MAX_CONNECTIONS=8 SAMPLE_SHUFFLE=42 MAX_GEN_TOKENS=65536 \
  bash scripts/run_scicode.sh

# ── Category: Agentic coding (BFCL -> SWE-bench Pro -> DeepSWE) ──
RUN_ID=<run-id> TEST_CATEGORY=single_turn MAX_GEN_TOKENS=65536 \
  bash scripts/run_bfcl.sh ; \
RUN_ID=<run-id> WORKERS=4 EVAL_WORKERS=4 LIMIT=200 MAX_GEN_TOKENS=65536 \
  bash scripts/run_swebench_pro.sh ; \
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 bash scripts/run_deepswe.sh 64 8
```

**Note:** thứ tự trong category Agentic đặt BFCL trước vì nhanh nhất, DeepSWE cuối cùng để chốt CCU 8 sau khi đã rảnh tay theo dõi (SWE-bench Pro chạy lâu nhất, ~11h36m, nên là bottleneck của category này chứ không phải thứ tự). Ở đây DeepSWE viết gọn thành 1 lệnh `64 8` (chạy thẳng full 64 task ở CCU8 ngay từ đầu) — khác với lịch sử thật đã chạy (3 batch CCU8/16/8 do dò CCU giữa chừng, xem phần "Lệnh chạy từng benchmark" ở trên); dùng bản gọn này cho model mới vì CCU8 đã được xác nhận là mức an toàn, không cần lặp lại việc dò CCU16 nữa. Trước khi chạy cho model mới, chạy thử ở tier Smoke để xác nhận các flag trên còn đúng với version script hiện tại — GPQA/MMLU-Pro/BFCL/SWE-bench Pro vẫn còn **(reconstructed)** vì lệnh gốc của lần chạy `glm5.2-selfhost-extended` đã trôi khỏi tmux history (history-limit 2000 dòng, log quá dài) khi sweep lại ngày 2026-09-10; LiveCodeBench và SciCode đã **(confirmed)** lại được từ tmux scrollback.

## Decision and report

- **Decision:** category, tier, reason, model, endpoint, sample-manifest version, per-benchmark concurrency, endpoint cap.
- **Report:** run URL/ID, commit, samples requested/valid/failed, score, wall time, token usage/cost, retry/error rate, and artifact link.
- **Comparison gate:** same dataset revision, manifest, prompt/harness revision, generation settings, scorer, and tier.
- **Promotion:** Smoke passed -> Balanced; Balanced stable -> Extended; Extended reviewed -> Full.

Full results are the only announcement-grade results. Any partial, retried, or non-comparable run must be labeled explicitly.
