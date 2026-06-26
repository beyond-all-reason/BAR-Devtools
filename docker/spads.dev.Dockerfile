# From-scratch SPADS image (replaces the EOL badosu/spads base). Modern Debian
# gives us the perl deps current SPADS needs -- FFI::Platypus for the unitsync
# binding, Inline::Python for the BAR plugins (ModeCommand), IO::Socket::SSL.
# spadsInstaller --auto installs a consistent current SPADS + manages the BAR
# engine; we override the lobby config for the dockerized teiserver at runtime.
FROM docker.io/debian:trixie-slim

RUN apt-get -y update \
  && apt-get -y upgrade \
  && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
  ca-certificates \
  wget \
  iproute2 \
  perl-modules-5.40 \
  libffi-platypus-perl \
  libio-socket-ssl-perl \
  libdbd-sqlite3-perl \
  libanyevent-perl \
  libinline-python-perl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/spads
RUN wget http://planetspads.free.fr/spads/installer/spadsInstaller.tar -qO - | tar x
RUN perl spadsInstaller.pl --auto BarLanServerTest
