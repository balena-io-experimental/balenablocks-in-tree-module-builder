FROM balenalib/aarch64-debian-python:3.7.4-build

RUN install_packages \
    awscli \
    bc \
    bison \
    flex \
    libelf-dev \
    libssl-dev

WORKDIR /usr/src/app
COPY build.sh /usr/local/bin/itkm_builder
RUN chmod +x /usr/local/bin/itkm_builder
COPY workarounds.sh /usr/local/bin

