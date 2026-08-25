# PC 목소리 학습 파이프라인 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용자의 목소리를 5가지 톤(내레이션/주인공/악역/조연/다정한캐릭터)으로 녹음한 데이터를 가지고,
Piper(VITS) 공식 한국어 사전학습 체크포인트를 파인튜닝하여 안드로이드 앱에 넣을 수 있는
스타일별 `.onnx` 음성 모델 5개를 만든다.

**Architecture:** `piper1-gpl`(OHF-Voice) 학습 도구를 WSL2(Ubuntu) 안에서 사용. 공식 한국어
체크포인트(`rhasspy/piper-checkpoints`의 `ko/ko_KR/kss/medium`)를 스타일별로 각각 파인튜닝한다.
g2pK로 녹음 스크립트 문장의 발음을 먼저 교정한 뒤(예: "좋아요"→"조아요"), 그 교정된 텍스트를
체크포인트와 동일한 `espeak-ng ko` 파이프라인에 그대로 통과시킨다 — phoneme_type을 바꾸면
사전학습된 임베딩과 어긋나므로 절대 바꾸지 않는다.

**Tech Stack:** Python 3.10+, piper1-gpl (PyTorch Lightning 기반 VITS 학습기), g2pK, huggingface_hub, pytest

**Spec:** [docs/superpowers/specs/2026-08-25-voice-storybook-reader-design.md](../specs/2026-08-25-voice-storybook-reader-design.md)

## Global Constraints

- 실행 환경은 WSL2(Ubuntu) — piper1-gpl이 `apt-get`/`cmake`/`ninja-build` 등 리눅스 빌드 도구를 요구함.
- GPU는 RTX 3060 Laptop (VRAM 6GB) — 공식 권장 최소 사양(8GB)보다 낮으므로 `batch_size`는
  기본값 32가 아니라 8에서 시작하고, OOM 발생 시 더 낮춘다 (조정 가능한 값으로 스크립트에 노출할 것).
- 샘플레이트는 항상 22050Hz (체크포인트와 일치해야 함).
- `phoneme_type`은 항상 `espeak`, `espeak_voice`는 항상 `ko`로 고정 — 절대 `text`/`phoneme_ids` 모드로
  바꾸지 않는다 (사전학습 체크포인트의 심볼 테이블과 어긋나 파인튜닝 이점이 사라짐).
- g2pK는 텍스트를 espeak-ng에 넘기기 전 발음을 교정하는 전처리 단계로만 사용한다.
- 스타일 5종 고정: `내레이션`, `주인공`, `악역`, `조연`, `다정한캐릭터`.

---

## File Structure

```
pc-voice-training/
  requirements.txt
  scripts/
    verify_setup.py
    sentence_bank.py
    generate_recording_script.py
    korean_phonemize.py
    build_metadata.py
    run_finetune.py
    export_and_verify.py
  tests/
    test_generate_recording_script.py
    test_korean_phonemize.py
    test_build_metadata.py
    test_run_finetune.py
  recording_scripts/   # generate_recording_script.py 출력물 (gitignore 대상 아님, 텍스트라 커밋 가능)
  data/                 # 사용자가 녹음한 wav 파일 (.gitignore)
  checkpoints/           # 다운로드한 사전학습 체크포인트 (.gitignore)
  output/                # 최종 스타일별 .onnx 결과물 (.gitignore, 별도로 안드로이드 프로젝트에 복사)
  piper1-gpl/            # 클론한 외부 저장소 (.gitignore)
  .gitignore
```

---

### Task 1: WSL2 환경 설정 + piper1-gpl 설치 + 체크포인트 다운로드

**Files:**
- Create: `pc-voice-training/.gitignore`
- Create: `pc-voice-training/requirements.txt`
- Create: `pc-voice-training/scripts/verify_setup.py`

**Interfaces:**
- Produces: 동작하는 `pc-voice-training/piper1-gpl/.venv` (Python venv), `pc-voice-training/checkpoints/`
  안에 `.ckpt`와 `config.json` 파일 (파일명은 실행 시 자동 조회 — 하드코딩하지 않음).

- [ ] **Step 1: WSL2/Ubuntu 설치 확인**

PowerShell(관리자)에서:
```powershell
wsl --list --verbose
```
Ubuntu가 없으면:
```powershell
wsl --install -d Ubuntu
```
설치 후 재부팅이 필요할 수 있음. 이후 모든 단계는 `wsl` 안(Ubuntu 셸)에서 실행한다.

- [ ] **Step 2: 시스템 의존성 설치 (WSL Ubuntu 안에서)**

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake ninja-build python3-venv python3-pip git
```

- [ ] **Step 3: WSL 안에서 GPU 인식 확인**

```bash
nvidia-smi
```
Expected: `NVIDIA GeForce RTX 3060 Laptop GPU`가 출력되고 VRAM 6GB 정도로 표시됨. 안 뜨면
Windows 쪽 NVIDIA 드라이버를 WSL CUDA 지원 버전으로 업데이트해야 함 (최신 드라이버는 대부분 기본 지원).

- [ ] **Step 4: 프로젝트 폴더 생성 및 piper1-gpl 클론**

```bash
mkdir -p ~/pc-voice-training && cd ~/pc-voice-training
git clone https://github.com/OHF-Voice/piper1-gpl.git
cd piper1-gpl
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -e '.[train]'
./build_monotonic_align.sh
python3 setup.py build_ext --inplace
```

- [ ] **Step 5: 프로젝트 자체 의존성 정의**

`pc-voice-training/requirements.txt`:
```
huggingface_hub
g2pk
jamo
pytest
```

설치:
```bash
cd ~/pc-voice-training
source piper1-gpl/.venv/bin/activate
pip install -r requirements.txt
```

g2pK가 mecab 관련 시스템 패키지를 요구해 설치 에러가 나면, 에러 메시지에 나오는 패키지명으로
`sudo apt-get install -y <패키지명>` 후 재시도 — g2pK 버전마다 요구 패키지가 달라 여기서 고정 명령을
단정하지 않는다.

- [ ] **Step 6: `.gitignore` 작성**

`pc-voice-training/.gitignore`:
```
piper1-gpl/
checkpoints/
data/
output/
*.wav
__pycache__/
*.pyc
.venv/
```

- [ ] **Step 7: 한국어 체크포인트 다운로드 스크립트 작성**

`pc-voice-training/scripts/verify_setup.py`:
```python
"""PC 학습 환경이 제대로 준비됐는지 확인하고, 한국어 사전학습 체크포인트를 내려받는다."""
import os
import sys
from pathlib import Path

CHECKPOINTS_DIR = Path(__file__).resolve().parent.parent / "checkpoints"


def check_torch_cuda() -> None:
    import torch

    print(f"torch version: {torch.__version__}")
    print(f"CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"GPU: {torch.cuda.get_device_name(0)}")
        vram_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
        print(f"VRAM: {vram_gb:.1f} GB")
    else:
        print("WARNING: CUDA not available, training will fall back to CPU (very slow)")


def check_g2pk() -> None:
    from g2pk import G2p

    g2p = G2p()
    result = g2p("좋아요")
    print(f"g2pK sanity check: 좋아요 -> {result}")
    assert result == "조아요", f"Unexpected g2pK output: {result}"


def download_korean_checkpoint() -> tuple[Path, Path]:
    from huggingface_hub import hf_hub_download, list_repo_files

    repo_id = "rhasspy/piper-checkpoints"
    files = list_repo_files(repo_id, repo_type="dataset")
    ko_files = [f for f in files if f.startswith("ko/ko_KR/kss/medium/")]
    if not ko_files:
        raise RuntimeError("ko/ko_KR/kss/medium 경로에서 파일을 찾지 못했습니다")

    ckpt_name = next(f for f in ko_files if f.endswith(".ckpt"))
    config_name = next(f for f in ko_files if f.endswith("config.json"))

    CHECKPOINTS_DIR.mkdir(parents=True, exist_ok=True)
    ckpt_path = hf_hub_download(
        repo_id, ckpt_name, repo_type="dataset", local_dir=str(CHECKPOINTS_DIR)
    )
    config_path = hf_hub_download(
        repo_id, config_name, repo_type="dataset", local_dir=str(CHECKPOINTS_DIR)
    )
    print(f"checkpoint: {ckpt_path}")
    print(f"config: {config_path}")
    return Path(ckpt_path), Path(config_path)


def main() -> int:
    check_torch_cuda()
    check_g2pk()
    ckpt_path, config_path = download_korean_checkpoint()
    if not ckpt_path.exists() or not config_path.exists():
        print("ERROR: 체크포인트 다운로드 실패", file=sys.stderr)
        return 1
    print("모든 환경 확인 완료.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 8: 실행해서 확인**

```bash
cd ~/pc-voice-training
source piper1-gpl/.venv/bin/activate
python3 scripts/verify_setup.py
```
Expected: `CUDA available: True`, GPU 이름과 VRAM(약 6GB) 출력, g2pK 체크 통과, 체크포인트/설정
파일 경로 출력 후 "모든 환경 확인 완료." 출력.

- [ ] **Step 9: Commit**

```bash
git add pc-voice-training/.gitignore pc-voice-training/requirements.txt pc-voice-training/scripts/verify_setup.py
git commit -m "Add PC training environment setup and checkpoint download script"
```

---

### Task 2: 녹음 스크립트 생성기

**Files:**
- Create: `pc-voice-training/scripts/sentence_bank.py`
- Create: `pc-voice-training/scripts/generate_recording_script.py`
- Test: `pc-voice-training/tests/test_generate_recording_script.py`

**Interfaces:**
- Consumes: 없음 (독립 실행 가능)
- Produces: `STYLES: list[str]`, `SENTENCE_BANK: dict[str, list[str]]` (sentence_bank.py),
  `generate_script(style: str, extra_sentences_path: Path | None = None) -> list[tuple[str, str]]`
  반환값은 `[("0001", "문장"), ("0002", "문장"), ...]` — 이 id는 Task 4에서 wav 파일명과 매칭하는 데 쓰임.

- [ ] **Step 1: 문장 뱅크 작성**

`pc-voice-training/scripts/sentence_bank.py`:
```python
STYLES = ["내레이션", "주인공", "악역", "조연", "다정한캐릭터"]

SENTENCE_BANK: dict[str, list[str]] = {
    "내레이션": [
        "옛날 옛적, 깊은 숲속에 작은 오두막이 있었습니다.",
        "해가 저물고 하늘은 붉은빛으로 물들었습니다.",
        "아이는 조용히 창밖을 바라보았습니다.",
        "강물은 천천히 마을을 지나 바다로 흘러갔습니다.",
        "겨울이 되자 온 마을이 하얀 눈으로 뒤덮였습니다.",
        "그날 밤, 별들이 유난히 밝게 빛났습니다.",
        "시간이 흘러 계절이 세 번 바뀌었습니다.",
        "오래된 나무 밑에는 작은 샘물이 흐르고 있었습니다.",
        "바람이 잔잔히 불어와 나뭇잎을 흔들었습니다.",
        "그렇게 하루가 저물어 갔습니다.",
    ],
    "주인공": [
        "나는 꼭 저 산 너머에 무엇이 있는지 알아낼 거야.",
        "무섭지만, 친구를 구하러 가야만 해.",
        "잠깐, 저기 좀 봐! 뭔가 반짝이고 있어.",
        "포기하지 않을 거야, 끝까지 해낼 거야.",
        "이 문 뒤에는 대체 무엇이 있을까?",
        "좋아, 이번엔 내가 앞장설게.",
        "정말 이상하다, 이런 건 처음 봐.",
        "우리 힘을 합치면 분명 해낼 수 있어.",
        "걱정 마, 내가 반드시 지켜줄게.",
        "드디어 해냈어! 우리가 해낸 거야!",
    ],
    "악역": [
        "흐흐, 드디어 너를 잡았구나.",
        "이 숲을 지나가려면 나에게 허락을 받아야 한다.",
        "감히 내 성에 발을 들이다니.",
        "너희가 아무리 애써도 소용없다.",
        "이제 도망칠 곳은 없다.",
        "내가 시키는 대로 하지 않으면 후회하게 될 거다.",
        "크하하, 그것참 재미있는 생각이군.",
        "조용히 하지 않으면 재미없을 줄 알아라.",
        "이 성의 주인은 바로 나다.",
        "마지막 경고다, 물러서라.",
    ],
    "조연": [
        "괜찮아? 다친 데는 없어?",
        "우리가 도와줄게, 걱정하지 마.",
        "저기 좀 봐, 방금 이상한 소리가 났어.",
        "같이 가자, 혼자 가면 위험해.",
        "정말 다행이다, 무사히 도착했구나.",
        "잠깐만 기다려줘, 금방 따라갈게.",
        "이거 받아, 분명 도움이 될 거야.",
        "우와, 저것 좀 봐! 정말 신기하다.",
        "힘내, 넌 할 수 있어.",
        "조심해, 앞에 뭔가 있어.",
    ],
    "다정한캐릭터": [
        "아가야, 이제 잘 시간이란다.",
        "오늘 하루도 정말 수고 많았어.",
        "걱정하지 마, 내가 옆에 있을게.",
        "따뜻한 차 한 잔 마시고 쉬렴.",
        "언제나 너를 사랑한단다.",
        "무슨 일이 있어도 네 편이야.",
        "이리 오렴, 꼭 안아줄게.",
        "잘 자, 좋은 꿈 꾸렴.",
        "네가 있어서 참 행복하구나.",
        "천천히 해도 괜찮아, 서두르지 않아도 돼.",
    ],
}
```

- [ ] **Step 2: 실패하는 테스트 작성**

`pc-voice-training/tests/test_generate_recording_script.py`:
```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from generate_recording_script import generate_script
from sentence_bank import SENTENCE_BANK, STYLES


def test_generate_script_returns_ids_matching_bank_order():
    result = generate_script("내레이션")
    expected_first_sentence = SENTENCE_BANK["내레이션"][0]
    assert result[0] == ("0001", expected_first_sentence)
    assert len(result) == len(SENTENCE_BANK["내레이션"])


def test_generate_script_ids_are_zero_padded_and_sequential():
    result = generate_script("주인공")
    ids = [item[0] for item in result]
    assert ids == [f"{i:04d}" for i in range(1, len(ids) + 1)]


def test_generate_script_unknown_style_raises():
    import pytest

    with pytest.raises(KeyError):
        generate_script("존재하지않는스타일")


def test_generate_script_extra_sentences_appended(tmp_path):
    extra_file = tmp_path / "extra.txt"
    extra_file.write_text("추가된 문장 하나.\n추가된 문장 둘.\n", encoding="utf-8")

    result = generate_script("악역", extra_sentences_path=extra_file)

    base_count = len(SENTENCE_BANK["악역"])
    assert len(result) == base_count + 2
    assert result[base_count] == (f"{base_count + 1:04d}", "추가된 문장 하나.")


def test_generate_script_writes_recording_script_file(tmp_path, monkeypatch):
    import generate_recording_script as grs

    monkeypatch.setattr(grs, "OUTPUT_DIR", tmp_path)
    grs.write_recording_script("다정한캐릭터")

    output_file = tmp_path / "다정한캐릭터.txt"
    assert output_file.exists()
    first_line = output_file.read_text(encoding="utf-8").splitlines()[0]
    assert first_line == f"0001. {SENTENCE_BANK['다정한캐릭터'][0]}"
```

- [ ] **Step 3: 테스트 실행해서 실패 확인**

```bash
cd ~/pc-voice-training
source piper1-gpl/.venv/bin/activate
pytest tests/test_generate_recording_script.py -v
```
Expected: FAIL (ModuleNotFoundError: generate_recording_script 없음)

- [ ] **Step 4: 구현 작성**

`pc-voice-training/scripts/generate_recording_script.py`:
```python
"""스타일별 녹음 스크립트(문장 번호 + 문장)를 만들고 텍스트 파일로 저장한다."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_bank import SENTENCE_BANK, STYLES  # noqa: E402

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "recording_scripts"


def generate_script(
    style: str, extra_sentences_path: Path | None = None
) -> list[tuple[str, str]]:
    sentences = list(SENTENCE_BANK[style])
    if extra_sentences_path is not None:
        extra_lines = extra_sentences_path.read_text(encoding="utf-8").splitlines()
        sentences.extend(line for line in extra_lines if line.strip())

    return [(f"{i:04d}", sentence) for i, sentence in enumerate(sentences, start=1)]


def write_recording_script(style: str, extra_sentences_path: Path | None = None) -> Path:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    items = generate_script(style, extra_sentences_path)
    output_file = OUTPUT_DIR / f"{style}.txt"
    lines = [f"{item_id}. {sentence}" for item_id, sentence in items]
    output_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return output_file


if __name__ == "__main__":
    for style in STYLES:
        path = write_recording_script(style)
        print(f"{style}: {path}")
```

- [ ] **Step 5: 테스트 실행해서 통과 확인**

```bash
pytest tests/test_generate_recording_script.py -v
```
Expected: 5개 테스트 모두 PASS

- [ ] **Step 6: 실제로 5개 스크립트 생성**

```bash
python3 scripts/generate_recording_script.py
```
Expected: `recording_scripts/` 아래 5개 `.txt` 파일 생성, 각각 콘솔에 경로 출력.

- [ ] **Step 7: Commit**

```bash
git add pc-voice-training/scripts/sentence_bank.py pc-voice-training/scripts/generate_recording_script.py pc-voice-training/tests/test_generate_recording_script.py pc-voice-training/recording_scripts/
git commit -m "Add recording script generator with per-style sentence bank"
```

---

### Task 3: 한국어 발음 정규화기 (g2pK 래퍼)

**Files:**
- Create: `pc-voice-training/scripts/korean_phonemize.py`
- Test: `pc-voice-training/tests/test_korean_phonemize.py`

**Interfaces:**
- Consumes: 없음
- Produces: `normalize_pronunciation(text: str) -> str`

- [ ] **Step 1: 실패하는 테스트 작성**

`pc-voice-training/tests/test_korean_phonemize.py`:
```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from korean_phonemize import normalize_pronunciation


def test_normalize_pronunciation_liaison():
    assert normalize_pronunciation("좋아요") == "조아요"


def test_normalize_pronunciation_preserves_punctuation():
    result = normalize_pronunciation("정말 다행이다, 무사히 도착했구나.")
    assert result.endswith("구나.")
    assert "," in result
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

```bash
pytest tests/test_korean_phonemize.py -v
```
Expected: FAIL (ModuleNotFoundError)

- [ ] **Step 3: 구현 작성**

`pc-voice-training/scripts/korean_phonemize.py`:
```python
"""g2pK로 한국어 문장의 발음을 교정한다. espeak-ng(ko)에 넘기기 전 전처리 단계로만 쓴다."""
from g2pk import G2p

_g2p = G2p()


def normalize_pronunciation(text: str) -> str:
    return _g2p(text)
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

```bash
pytest tests/test_korean_phonemize.py -v
```
Expected: 2개 테스트 PASS

- [ ] **Step 5: Commit**

```bash
git add pc-voice-training/scripts/korean_phonemize.py pc-voice-training/tests/test_korean_phonemize.py
git commit -m "Add g2pK pronunciation normalizer"
```

---

### Task 4: 데이터셋 빌더 (녹음 wav + 스크립트 → metadata.csv)

**Files:**
- Create: `pc-voice-training/scripts/build_metadata.py`
- Test: `pc-voice-training/tests/test_build_metadata.py`

**Interfaces:**
- Consumes: `generate_script(style)` (Task 2), `normalize_pronunciation(text)` (Task 3)
- Produces: `build_metadata(style: str, data_dir: Path, output_dir: Path) -> Path` — Piper가 요구하는
  `filename|text` 형식의 `metadata.csv`를 만들어 반환 경로를 준다. `text`는 g2pK로 교정된 문장.

- [ ] **Step 1: 실패하는 테스트 작성**

`pc-voice-training/tests/test_build_metadata.py`:
```python
import sys
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from build_metadata import build_metadata, MissingRecordingError


def _write_silent_wav(path: Path, seconds: float = 0.5, sample_rate: int = 22050) -> None:
    n_frames = int(seconds * sample_rate)
    with wave.open(str(path), "w") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(b"\x00\x00" * n_frames)


def test_build_metadata_writes_expected_csv_lines(tmp_path, monkeypatch):
    import sentence_bank

    monkeypatch.setitem(
        sentence_bank.SENTENCE_BANK, "테스트스타일", ["좋아요.", "안녕하세요."]
    )

    data_dir = tmp_path / "data" / "테스트스타일"
    data_dir.mkdir(parents=True)
    _write_silent_wav(data_dir / "0001.wav")
    _write_silent_wav(data_dir / "0002.wav")

    output_dir = tmp_path / "output"
    csv_path = build_metadata("테스트스타일", tmp_path / "data", output_dir)

    lines = csv_path.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "0001.wav|조아요."
    assert lines[1] == "0002.wav|안녕하세요."


def test_build_metadata_raises_on_missing_wav(tmp_path, monkeypatch):
    import sentence_bank

    monkeypatch.setitem(
        sentence_bank.SENTENCE_BANK, "테스트스타일2", ["문장 하나.", "문장 둘."]
    )

    data_dir = tmp_path / "data" / "테스트스타일2"
    data_dir.mkdir(parents=True)
    _write_silent_wav(data_dir / "0001.wav")
    # 0002.wav 는 일부러 만들지 않음

    with pytest.raises(MissingRecordingError, match="0002.wav"):
        build_metadata("테스트스타일2", tmp_path / "data", tmp_path / "output")
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

```bash
pytest tests/test_build_metadata.py -v
```
Expected: FAIL (ModuleNotFoundError)

- [ ] **Step 3: 구현 작성**

`pc-voice-training/scripts/build_metadata.py`:
```python
"""녹음된 wav 파일과 문장 스크립트를 합쳐 Piper용 metadata.csv를 만든다."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_recording_script import generate_script  # noqa: E402
from korean_phonemize import normalize_pronunciation  # noqa: E402


class MissingRecordingError(Exception):
    pass


def build_metadata(style: str, data_root: Path, output_dir: Path) -> Path:
    style_dir = data_root / style
    items = generate_script(style)

    lines = []
    for item_id, sentence in items:
        wav_name = f"{item_id}.wav"
        wav_path = style_dir / wav_name
        if not wav_path.exists():
            raise MissingRecordingError(
                f"{wav_name} 파일이 {style_dir}에 없습니다. 녹음을 먼저 완료하세요."
            )
        normalized = normalize_pronunciation(sentence)
        lines.append(f"{wav_name}|{normalized}")

    output_dir.mkdir(parents=True, exist_ok=True)
    csv_path = output_dir / f"metadata_{style}.csv"
    csv_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return csv_path


if __name__ == "__main__":
    import sentence_bank

    project_root = Path(__file__).resolve().parent.parent
    for style in sentence_bank.STYLES:
        try:
            path = build_metadata(style, project_root / "data", project_root / "output" / "metadata")
            print(f"{style}: {path}")
        except MissingRecordingError as e:
            print(f"{style}: 건너뜀 ({e})")
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

```bash
pytest tests/test_build_metadata.py -v
```
Expected: 2개 테스트 PASS

- [ ] **Step 5: Commit**

```bash
git add pc-voice-training/scripts/build_metadata.py pc-voice-training/tests/test_build_metadata.py
git commit -m "Add metadata.csv builder combining recordings and g2pK-normalized text"
```

---

### Task 5: 파인튜닝 실행 러너

**Files:**
- Create: `pc-voice-training/scripts/run_finetune.py`
- Test: `pc-voice-training/tests/test_run_finetune.py`

**Interfaces:**
- Consumes: `checkpoints/*.ckpt`, `checkpoints/*config.json` (Task 1), `output/metadata/metadata_{style}.csv`
  (Task 4), `data/{style}/*.wav` (사용자 녹음)
- Produces: `build_finetune_command(style: str, batch_size: int = 8, fast_dev_run: bool = False) -> list[str]`
  (subprocess 인자 리스트), 실행 시 `output/lightning_logs/{style}/`에 체크포인트 생성.

- [ ] **Step 1: 실패하는 테스트 작성**

`pc-voice-training/tests/test_run_finetune.py`:
```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from run_finetune import build_finetune_command


def test_build_finetune_command_uses_espeak_ko_and_correct_sample_rate(tmp_path):
    cmd = build_finetune_command(
        style="내레이션",
        checkpoint_path=tmp_path / "ko_kss_medium.ckpt",
        config_path=tmp_path / "config.json",
        csv_path=tmp_path / "metadata_내레이션.csv",
        audio_dir=tmp_path / "data" / "내레이션",
        cache_dir=tmp_path / "cache" / "내레이션",
        batch_size=8,
    )

    joined = " ".join(cmd)
    assert "--data.espeak_voice" in cmd
    assert cmd[cmd.index("--data.espeak_voice") + 1] == "ko"
    assert "--model.sample_rate" in cmd
    assert cmd[cmd.index("--model.sample_rate") + 1] == "22050"
    assert "--data.batch_size" in cmd
    assert cmd[cmd.index("--data.batch_size") + 1] == "8"
    assert "--data.phoneme_type" not in joined  # 기본값(espeak)을 그대로 사용, 절대 text로 바꾸지 않음


def test_build_finetune_command_fast_dev_run_flag(tmp_path):
    cmd = build_finetune_command(
        style="내레이션",
        checkpoint_path=tmp_path / "ckpt",
        config_path=tmp_path / "config.json",
        csv_path=tmp_path / "metadata.csv",
        audio_dir=tmp_path / "data",
        cache_dir=tmp_path / "cache",
        fast_dev_run=True,
    )
    assert "--trainer.fast_dev_run" in cmd
    assert cmd[cmd.index("--trainer.fast_dev_run") + 1] == "true"
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

```bash
pytest tests/test_run_finetune.py -v
```
Expected: FAIL (ModuleNotFoundError)

- [ ] **Step 3: 구현 작성**

`pc-voice-training/scripts/run_finetune.py`:
```python
"""스타일별 Piper 파인튜닝 명령을 구성하고 실행한다."""
import argparse
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
VENV_PYTHON = PROJECT_ROOT / "piper1-gpl" / ".venv" / "bin" / "python3"


def build_finetune_command(
    style: str,
    checkpoint_path: Path,
    config_path: Path,
    csv_path: Path,
    audio_dir: Path,
    cache_dir: Path,
    batch_size: int = 8,
    fast_dev_run: bool = False,
) -> list[str]:
    cmd = [
        str(VENV_PYTHON),
        "-m",
        "piper.train",
        "fit",
        "--data.voice_name",
        f"ko_KR-{style}-medium",
        "--data.csv_path",
        str(csv_path),
        "--data.audio_dir",
        str(audio_dir),
        "--model.sample_rate",
        "22050",
        "--data.espeak_voice",
        "ko",
        "--data.cache_dir",
        str(cache_dir),
        "--data.config_path",
        str(config_path),
        "--data.batch_size",
        str(batch_size),
        "--ckpt_path",
        str(checkpoint_path),
    ]
    if fast_dev_run:
        cmd += ["--trainer.fast_dev_run", "true"]
    return cmd


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--style", required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--fast-dev-run", action="store_true")
    args = parser.parse_args()

    checkpoints_dir = PROJECT_ROOT / "checkpoints"
    checkpoint_path = next(checkpoints_dir.glob("*.ckpt"))
    config_path = next(checkpoints_dir.glob("*config.json"))
    csv_path = PROJECT_ROOT / "output" / "metadata" / f"metadata_{args.style}.csv"
    audio_dir = PROJECT_ROOT / "data" / args.style
    cache_dir = PROJECT_ROOT / "output" / "cache" / args.style

    cmd = build_finetune_command(
        style=args.style,
        checkpoint_path=checkpoint_path,
        config_path=config_path,
        csv_path=csv_path,
        audio_dir=audio_dir,
        cache_dir=cache_dir,
        batch_size=args.batch_size,
        fast_dev_run=args.fast_dev_run,
    )
    print("Running:", " ".join(cmd))
    result = subprocess.run(cmd)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

```bash
pytest tests/test_run_finetune.py -v
```
Expected: 2개 테스트 PASS

- [ ] **Step 5: 더미 데이터로 스모크 테스트 (실제 GPU 실행 확인)**

Task 4에서 만든 더미 wav(무음 0.5초짜리) 2개로 실제 `fast-dev-run` 1스텝을 돌려 명령 자체가
에러 없이 실행되는지 확인 (실제 학습 품질과 무관, 파이프라인 연결만 검증):
```bash
mkdir -p data/테스트스타일
python3 -c "
import sys; sys.path.insert(0, 'scripts')
from tests.test_build_metadata import _write_silent_wav
" 2>/dev/null || true
python3 - <<'EOF'
import wave
from pathlib import Path

def write_silent_wav(path, seconds=0.5, sr=22050):
    with wave.open(str(path), "w") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(sr)
        f.writeframes(b"\x00\x00" * int(seconds * sr))

Path("data/테스트스타일").mkdir(parents=True, exist_ok=True)
write_silent_wav("data/테스트스타일/0001.wav")
write_silent_wav("data/테스트스타일/0002.wav")
EOF

python3 -c "
import sys; sys.path.insert(0, 'scripts')
import sentence_bank
sentence_bank.SENTENCE_BANK['테스트스타일'] = ['좋아요.', '안녕하세요.']
from build_metadata import build_metadata
from pathlib import Path
build_metadata('테스트스타일', Path('data'), Path('output/metadata'))
"

python3 scripts/run_finetune.py --style 테스트스타일 --fast-dev-run --batch-size 2
```
Expected: Lightning 학습 루프가 최소 1스텝 실행되고 에러 없이 종료 (OOM 발생 시 `--batch-size 1`로
재시도 — 이 값이 6GB VRAM 환경의 조정 포인트).

- [ ] **Step 6: Commit**

```bash
git add pc-voice-training/scripts/run_finetune.py pc-voice-training/tests/test_run_finetune.py
git commit -m "Add finetune command runner with fast-dev-run smoke test"
```

---

### Task 6: ONNX 익스포트 및 검증

**Files:**
- Create: `pc-voice-training/scripts/export_and_verify.py`

**Interfaces:**
- Consumes: `output/lightning_logs/{style}/**/*.ckpt` (Task 5 실제 학습 결과, 수동으로 실행 완료된 후)
- Produces: `output/onnx/ko_KR-{style}-medium.onnx` + `.onnx.json`, 검증용 `output/onnx/{style}_test.wav`

이 태스크는 Task 5의 실제(전체) 학습이 사용자가 수동으로 완료된 뒤에 실행하는 마무리 스크립트다.
자동화된 유닛테스트 대상이 아니라 실행 후 결과물을 귀로 확인하는 수동 검증 단계로 둔다 (전체 학습
자체가 스타일당 수 시간 걸리는 수동 작업이라 CI성 테스트로 만들 수 없음).

- [ ] **Step 1: 구현 작성**

`pc-voice-training/scripts/export_and_verify.py`:
```python
"""학습된 체크포인트를 onnx로 내보내고, 검증 문장을 합성해 들어본다."""
import argparse
import subprocess
import wave
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
VENV_PYTHON = PROJECT_ROOT / "piper1-gpl" / ".venv" / "bin" / "python3"

VALIDATION_SENTENCE = "이건 검증을 위한 문장입니다. 목소리가 잘 들리나요?"


def find_latest_checkpoint(style: str) -> Path:
    log_dir = PROJECT_ROOT / "output" / "lightning_logs" / style
    ckpts = sorted(log_dir.glob("**/*.ckpt"), key=lambda p: p.stat().st_mtime)
    if not ckpts:
        raise FileNotFoundError(f"{log_dir} 에서 학습된 체크포인트를 찾지 못했습니다")
    return ckpts[-1]


def export_onnx(style: str) -> Path:
    checkpoint = find_latest_checkpoint(style)
    onnx_dir = PROJECT_ROOT / "output" / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = onnx_dir / f"ko_KR-{style}-medium.onnx"

    cmd = [
        str(VENV_PYTHON),
        "-m",
        "piper.train.export_onnx",
        "--checkpoint",
        str(checkpoint),
        "--output-file",
        str(onnx_path),
    ]
    subprocess.run(cmd, check=True)
    return onnx_path


def synthesize_validation_clip(onnx_path: Path, style: str) -> Path:
    from piper import PiperVoice

    voice = PiperVoice.load(str(onnx_path))
    out_path = onnx_path.parent / f"{style}_test.wav"
    with wave.open(str(out_path), "w") as wav_file:
        voice.synthesize_wav(VALIDATION_SENTENCE, wav_file)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--style", required=True)
    args = parser.parse_args()

    onnx_path = export_onnx(args.style)
    print(f"exported: {onnx_path}")

    wav_path = synthesize_validation_clip(onnx_path, args.style)
    with wave.open(str(wav_path)) as f:
        duration = f.getnframes() / f.getframerate()
    print(f"validation clip: {wav_path} ({duration:.1f}s)")
    if duration < 0.5:
        print("WARNING: 생성된 오디오가 너무 짧습니다. 학습이 제대로 안 됐을 수 있습니다.")
        return 1
    print("이 파일을 직접 들어보고 목소리 품질을 확인하세요.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 실제 학습 완료 후 실행 (수동)**

```bash
python3 scripts/export_and_verify.py --style 내레이션
```
Expected: `output/onnx/ko_KR-내레이션-medium.onnx`(+`.onnx.json`)와 `output/onnx/내레이션_test.wav` 생성,
duration이 0.5초 이상. 생성된 wav를 직접 들어서 (a) 본인 목소리로 들리는지, (b) 발음이 자연스러운지
확인 — 이 판단은 자동화할 수 없는 사람의 귀 검증.

- [ ] **Step 3: Commit**

```bash
git add pc-voice-training/scripts/export_and_verify.py
git commit -m "Add onnx export and validation synthesis script"
```

---

## Self-Review 결과

- **스펙 커버리지**: 녹음 스크립트 생성(Task 2), 학습 파이프라인(Task 1/5), g2pK 통합(Task 3/4),
  스타일 5종(Task 2 sentence_bank), onnx 결과물 산출(Task 6) — 스펙의 "녹음 데이터 수집"과 "학습
  파이프라인" 섹션을 모두 커버함. 안드로이드 앱 관련 기능(파싱/재생/매핑 UI)은 별도 계획(Android 앱
  Implementation Plan)에서 다룸.
- **플레이스홀더 스캔**: 없음 — 모든 스텝에 실행 가능한 실제 코드/명령어 포함.
- **타입/시그니처 일관성**: `generate_script`가 Task 2~4에서 동일한 `list[tuple[str, str]]` 반환,
  `normalize_pronunciation`이 Task 3~4에서 동일 시그니처로 사용됨. 확인 완료.
