FROM python:3.7-slim

# Install packages needed to run your application (not build deps):
#   mime-support -- for mime types when serving static files
#   postgresql-client -- for running database commands
# We need to recreate the /usr/share/man/man{1..8} directories first because they were clobbered by a parent image.
RUN set -ex \
	&& seq 1 8 | xargs -I{} mkdir -p /usr/share/man/man{} \
	&& apt-get update && apt-get install -y --no-install-recommends \
		mime-support \
		postgresql-client \
	&& rm -rf /var/lib/apt/lists/*

# Copy in your requirements file
ADD requirements.txt /requirements.txt

# OR, if you’re using a directory for your requirements, copy everything (comment out the above and uncomment this if so):
# ADD requirements /requirements

# Install build deps, then run `pip install`, then remove unneeded build deps all in a single step. Correct the path to your production requirements file, if needed.
RUN set -ex \
	&& BUILD_DEPS="build-essential libpq-dev" \
	\
	&& apt-get update && apt-get install -y --no-install-recommends $BUILD_DEPS \
	&& python3.7 -m venv /venv \
	&& /venv/bin/pip install -U pip \
	&& /venv/bin/pip install --no-cache-dir -r /requirements.txt \
	\
	&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $BUILD_DEPS \
	&& rm -rf /var/lib/apt/lists/*

# Copy your application code to the container (make sure you create a .dockerignore file if any large files or directories should be excluded)
RUN mkdir /code/
WORKDIR /code/
ADD . /code/

# uWSGI will listen on this port
EXPOSE 8000

# Add any custom, static environment variables needed by Django or your settings file here:
ENV DJANGO_SETTINGS_MODULE=my_project.settings.deploy

# uWSGI configuration (customize as needed):
ENV UWSGI_VIRTUALENV=/venv UWSGI_WSGI_FILE=my_project/wsgi.py UWSGI_HTTP=:8000 UWSGI_MASTER=1 UWSGI_WORKERS=2 UWSGI_THREADS=8 UWSGI_UID=1000 UWSGI_GID=2000 UWSGI_LAZY_APPS=1 UWSGI_WSGI_ENV_BEHAVIOR=holy

# Call collectstatic (customize the following line with the minimal environment variables needed for manage.py to run):
RUN DATABASE_URL='' /venv/bin/python manage.py collectstatic --noinput

ENTRYPOINT ["/code/docker-entrypoint.sh"]

# Start uWSGI
CMD ["/venv/bin/uwsgi", "--http-auto-chunked", "--http-keepalive", "--static-map", "/static/=/code/static/", "--static-expires-uri", "/static/.*\\.[a-f0-9]{12,}\\.(css|js|png|jpg|jpeg|gif|ico|woff|ttf|otf|svg|scss|map|txt) 315360000"]