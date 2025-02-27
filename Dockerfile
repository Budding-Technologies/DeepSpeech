# Please refer to the USING documentation, "Dockerfile for building from source"

# Need devel version cause we need /usr/include/cudnn.h 
FROM nvidia/cuda:10.1-cudnn7-devel-ubuntu18.04

ENV DEEPSPEECH_REPO=https://github.com/mozilla/DeepSpeech.git \
    DEEPSPEECH_SHA=master

# >> START Install base software

# Get basic packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-utils \
    bash-completion \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    g++ \
    gcc \
    git \
    libbz2-dev \
    libboost-all-dev \
    libgsm1-dev \
    libltdl-dev \
    liblzma-dev \
    libmagic-dev \
    libpng-dev \
    libsox-fmt-mp3 \
    libsox-dev \
    locales \
    openjdk-8-jdk \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-wheel \
    python3-numpy \
    sox \
    unzip \
    wget \
    zlib1g-dev; \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3 1; \
    # Install Bazel \
    curl -LO "https://github.com/bazelbuild/bazel/releases/download/3.1.0/bazel_3.1.0-linux-x86_64.deb" && dpkg -i bazel_*.deb; \
    # Try and free some space \
    rm -rf /var/lib/apt/lists/* bazel_*.deb

# << END Install base software

# >> START Configure Tensorflow Build

# GPU Environment Setup
ENV TF_NEED_ROCM=0 \
    TF_NEED_OPENCL_SYCL=0 \
    TF_NEED_OPENCL=0 \
    TF_NEED_CUDA=1 \
    TF_CUDA_PATHS="/usr,/usr/local/cuda-10.1,/usr/lib/x86_64-linux-gnu/" \
    TF_CUDA_VERSION=10.1 \
    TF_CUDNN_VERSION=7.6 \
    TF_CUDA_COMPUTE_CAPABILITIES=6.0 \
    TF_NCCL_VERSION=2.8 \
    # Common Environment Setup \
    TF_BUILD_CONTAINER_TYPE=GPU \
    TF_BUILD_OPTIONS=OPT \
    TF_BUILD_DISABLE_GCP=1 \
    TF_BUILD_ENABLE_XLA=0 \
    TF_BUILD_PYTHON_VERSION=PYTHON3 \
    TF_BUILD_IS_OPT=OPT \
    TF_BUILD_IS_PIP=PIP \
    # Build client.cc and install Python client and decoder bindings \
    TFDIR=/DeepSpeech/tensorflow \
    # Allow Python printing utf-8 \
    PYTHONIOENCODING=UTF-8 \
    # Other Parameters \
    CC_OPT_FLAGS="-mavx -mavx2 -msse4.1 -msse4.2 -mfma" \
    TF_NEED_GCP=0 \
    TF_NEED_HDFS=0 \
    TF_NEED_JEMALLOC=1 \
    TF_NEED_OPENCL=0 \
    TF_CUDA_CLANG=0 \
    TF_NEED_MKL=0 \
    TF_ENABLE_XLA=0 \
    TF_NEED_AWS=0 \
    TF_NEED_KAFKA=0 \
    TF_NEED_NGRAPH=0 \
    TF_DOWNLOAD_CLANG=0 \
    TF_NEED_TENSORRT=0 \
    TF_NEED_GDR=0 \
    TF_NEED_VERBS=0 \
    TF_NEED_OPENCL_SYCL=0 \
    PYTHON_BIN_PATH=/usr/bin/python3.6 \
    PYTHON_LIB_PATH=/usr/local/lib/python3.6/dist-packages

# << END Configure Tensorflow Build

# >> START Configure Bazel

# Running bazel inside a `docker build` command causes trouble, cf:
#   https://github.com/bazelbuild/bazel/issues/134
# The easiest solution is to set up a bazelrc file forcing --batch.
# Similarly, we need to workaround sandboxing issues:
#   https://github.com/bazelbuild/bazel/issues/418
RUN echo "startup --batch" >>/etc/bazel.bazelrc; \
    echo "build --spawn_strategy=standalone --genrule_strategy=standalone" >> /etc/bazel.bazelrc

# << END Configure Bazel

WORKDIR /

RUN git clone --recursive $DEEPSPEECH_REPO DeepSpeech && \
    cd /DeepSpeech && \
    git fetch origin $DEEPSPEECH_SHA && git checkout $DEEPSPEECH_SHA; \
    git submodule sync tensorflow/ && git submodule update --init tensorflow/; \
    git submodule sync kenlm/ && git submodule update --init kenlm/

# >> START Build and bind
# Fix for not found script https://github.com/tensorflow/tensorflow/issues/471
# Using CPU optimizations:
# -mtune=generic -march=x86-64 -msse -msse2 -msse3 -msse4.1 -msse4.2 -mavx.
# Adding --config=cuda flag to build using CUDA.

# passing LD_LIBRARY_PATH is required cause Bazel doesn't pickup it from environment

# Build DeepSpeech
RUN cd /DeepSpeech/tensorflow && ./configure && bazel build \
	--workspace_status_command="bash native_client/bazel_workspace_status_cmd.sh" \
	--config=monolithic \
	--config=cuda \
	-c opt \
	--copt=-O3 \
	--copt="-D_GLIBCXX_USE_CXX11_ABI=0" \
	--copt=-mtune=generic \
	--copt=-march=x86-64 \
	--copt=-msse \
	--copt=-msse2 \
	--copt=-msse3 \
	--copt=-msse4.1 \
	--copt=-msse4.2 \
	--copt=-mavx \
	--copt=-fvisibility=hidden \
	//native_client:libdeepspeech.so \
	--verbose_failures \
	--action_env=LD_LIBRARY_PATH=${LD_LIBRARY_PATH} && \
    cp bazel-bin/native_client/libdeepspeech.so /DeepSpeech/native_client/ && \
    rm -fr /root/.cache/*

RUN cd /DeepSpeech/native_client && make NUM_PROCESSES=$(nproc) deepspeech ; \
    cd /DeepSpeech/native_client/python && make NUM_PROCESSES=$(nproc) bindings; \
    pip3 install --upgrade dist/*.whl; \
    cd /DeepSpeech/native_client/ctcdecode && make NUM_PROCESSES=$(nproc) bindings; \
    pip3 install --upgrade dist/*.whl

# << END Build and bind

# Build KenLM in /DeepSpeech/kenlm folder
WORKDIR /DeepSpeech/kenlm
RUN wget -O - https://gitlab.com/libeigen/eigen/-/archive/3.3.8/eigen-3.3.8.tar.bz2 | tar xj; \
    mkdir -p build && \
    cd build && \
    EIGEN3_ROOT=/DeepSpeech/kenlm/eigen-3.3.8 cmake .. && \
    make -j $(nproc)

# Done
WORKDIR /DeepSpeech
