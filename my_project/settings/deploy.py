from . import *
import dj_database_url

DEBUG = False

ALLOWED_HOSTS = ['localhost']

DATABASES['default'] = dj_database_url.config(conn_max_age=600)

STATIC_ROOT = os.path.join(BASE_DIR, 'static')

STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'
