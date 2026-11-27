[English](CONTRIBUTING.md) | [한국어](CONTRIBUTING.ko.md)

# 기여하기

기여는 이 저장소가 공개된 독립 교육용 프로젝트로서 계속 쓸모 있게 유지되도록 해야 합니다. 이 저장소는 AWS 공식 샘플이나 템플릿이 아닙니다.

## 변경을 제안하기 전에

1. 문제, 의도한 동작, 영향을 받는 실행 패턴을 설명하는 이슈를 여세요.
2. 가능하면 과학적 변경과 인프라 변경을 나누세요.
3. 새로운 생물정보학 용어나 클라우드 용어는 처음 쓸 때 쉬운 말로 설명하세요.
4. 비공개 데이터, 고객이나 개인 이름, 계정 ID, 리소스 식별자, 자격 증명, 비용, 실행 로그, 로컬 절대 경로를 넣지 마세요.
5. 별도 범위와 검증 모델을 먼저 합의하지 않은 채 분자 동역학 시뮬레이션을 추가하지 마세요.

## 개발 환경 설정

fork를 clone하고 저장소로 들어갑니다.

```bash
git clone 'https://github.com/<GITHUB_USER>/aptamer-workflows-on-aws.git'
cd aptamer-workflows-on-aws
git remote add upstream 'https://github.com/<UPSTREAM_ORGANIZATION>/aptamer-workflows-on-aws.git'
```

topic 브랜치를 만듭니다.

```bash
git fetch upstream
git switch --create '<TOPIC_BRANCH_NAME>' upstream/main
```

로컬 컨테이너를 빌드합니다.

```bash
docker build --tag aptamer-workflow:development .
```

## 필수 검사

저장소 루트에서 오프라인 검사를 실행하세요.

```bash
python3 -m unittest discover --start-directory tests --pattern 'test_*.py' --verbose
bash -n pipeline/run_pipeline.sh pipeline/s1_qc.sh pipeline/s2_trim.sh pipeline/s3_count.sh pipeline/s5_fold.sh ec2/run_baseline.sh nextflow/run_batch.sh healthomics/orchestrate.sh data/fetch_dra009383.sh
python3 -m py_compile pipeline/enrich.py tests/test_enrich.py
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
python3 -m json.tool healthomics/parameter-template.json >/dev/null
python3 -m json.tool healthomics/run-parameters.example.json >/dev/null
```

Nextflow를 쓸 수 있으면 모든 profile을 파싱하세요.

```bash
nextflow run nextflow/main.nf --help
nextflow config nextflow/nextflow.config -profile local >/dev/null
nextflow config nextflow/nextflow.config -profile batch >/dev/null
nextflow config nextflow/nextflow.config -profile batch_mountpoint >/dev/null
nextflow config nextflow/nextflow.config -profile healthomics >/dev/null
```

클라우드 테스트는 허가된 비프로덕션 환경에서만 실행하세요. 실행 전에 계획된 쓰기를 모두 검토하고, 정리는 별도의 dry run과 명시적인 승인을 거친 뒤에만 하세요.

## 과학적 변경

과학적 변경에는 다음을 적어야 합니다.

- 다루는 가설이나 결함
- 지원하는 분자 종류와 시퀀싱 구성
- 입력 가정
- 파라미터 기본값과 그 출처
- 예상 출력
- 양성, 음성, 경계 사례 테스트
- 해석의 한계

농축이 결합을 증명한다거나, 예측된 폴딩이 3차원 구조를 증명한다고 주장하지 마세요. D1은 공개 RNA/Ion Torrent 데이터이며 DNA/Illumina 데이터나 고객 데이터로 설명하면 안 됩니다.

## 스토리지 변경

Mountpoint 변경은 다음 규칙을 지켜야 합니다.

- 입력은 읽기 전용으로 마운트합니다.
- 임시 파일과 출력은 로컬 POSIX 스토리지에 둡니다.
- Mountpoint를 Nextflow work 디렉터리로 절대 쓰지 않습니다.
- 정확한 도구 버전과 파일 접근 패턴으로 테스트합니다.
- 마운트된 문자열 경로의 `-resume` 캐시 한계를 문서화합니다.

## 보안 변경

리소스는 기본적으로 private으로 두세요. 최소 권한 IAM 역할, private S3 버킷, private ECR 이미지, 암호화, 바뀌지 않는 실행 prefix를 쓰고, 비대화형 job에는 인바운드 네트워크 접근을 두지 마세요. [SECURITY.ko.md](SECURITY.ko.md)를 따르세요.

## 문서와 링크

명시적인 `<PLACEHOLDER_NAMES>`를 쓴 완전한 명령을 쓰세요. 인자를 생략하거나 점 세 개로 줄이지 마세요. 제출하기 전에 상대 링크를 테스트하고 외부 링크를 확인하세요. 영어 문서 `X.md`를 바꾸면 한국어 짝 문서 `X.ko.md`도 같은 제목, 명령, 링크로 맞춰 주세요.

## Pull request 체크리스트

- [ ] 변경의 목적이 하나로 분명하다.
- [ ] 테스트가 새 동작을 다룬다.
- [ ] 오프라인 검증을 통과한다.
- [ ] 문서가 새 용어를 쉬운 말로 설명한다.
- [ ] 명령이 완전하고 placeholder가 명시적이다.
- [ ] 공개 데이터와 과학적 한계 설명이 정확하다.
- [ ] 변경에 비공개 정보나 식별 정보가 없다.
- [ ] 어떤 리소스도 공개되지 않고, 인증이나 안전 통제가 약해지지 않는다.
- [ ] 정리 안내가 확인 또는 dry run으로 시작한다.
