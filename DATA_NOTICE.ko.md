[English](DATA_NOTICE.md) | [한국어](DATA_NOTICE.ko.md)

# 데이터 고지

이 저장소에는 시퀀싱 read나 연구 결과가 들어 있지 않습니다.

`data/dra009383_manifest.tsv`의 선택 예제 manifest는 시퀀싱 데이터 공개 저장소인 DDBJ Sequence Read Archive의 [DRA009383](https://ddbj.nig.ac.jp/resource/sra-submission/DRA009383)을 가리킵니다. 이 accession에는 RNA SELEX 실험의 0~8라운드에 해당하는 시퀀싱 run 아홉 개가 있습니다. SELEX는 표적에 결합하는 핵산 서열을 반복해서 선별하는 실험 과정입니다.

manifest에는 공개 accession 메타데이터, 다운로드 URL, 출력 파일 이름, 공개된 MD5 체크섬만 있습니다. `data/fetch_dra009383.sh`는 공개 아카이브에서 read를 직접 내려받고 파일마다 체크섬을 검증합니다. 내려받은 파일은 기본적으로 `inputs/` 아래에 저장되며 컨테이너 빌드 컨텍스트에서 제외됩니다. 선택 파일 `data/dra009383.env.example`에는 공개 예제를 재현할 수 있도록 연결된 연구에서 쓴 프라이머 서열이 기록되어 있습니다. 이 값이 다른 라이브러리에도 맞는다고 가정하면 안 됩니다.

관련 방법은 [RaptGen 논문](https://pmc.ncbi.nlm.nih.gov/articles/PMC10766510/)에 설명되어 있습니다.

데이터를 내려받거나 재배포하기 전에 아카이브 레코드, 연결된 논문, 데이터 이용 조건을 검토할 책임은 사용자에게 있습니다. DRA009383을 바탕으로 한 분석을 발표할 때는 원 연구와 accession을 인용하세요.
