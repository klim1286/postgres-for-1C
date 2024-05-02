# Установка postgres-for-1C 15.6 и настройка асинхронной потоковой репликации на ОС Linux Ubuntu

## 1. Подготовка серверов для 1С</a>
Установка языкового пакета (локали) русского языка на Ubuntu
Для нормального функционирования СУБД PostgreSQL установим на наш виртуальный сервер локализацию русского языка
```
sudo dpkg-reconfigure locales
sudo locale-gen en_US.UTF-8
sudo locale-gen ru_RU.UTF-8
sudo update-locale LANG=ru_RU.UTF8
```
Чтобы добраться до нужной локали используйте стрелки «вверх» — «вниз», а чтобы выбрать — «пробел».

Чтобы установить локаль русского языка основной для системы необходимо в следующем окне выбрать ее.

Перезагружаем Ubuntu
```
sudo shutdown -r now
```
или
```
sudo reboot
```
Как проверить установленные Локали в Ubuntu

После того, как вы установили локаль, она должна появиться в списке установленных, а также стать основной для системы (если мы это установили):
```
sudo locale
```

## 2. Установка postgresql pro для 1С
```
wget https://repo.postgrespro.ru/1c/1c-15/keys/pgpro-repo-add.sh
```

или скачать из этого репозитория, были случае когда путь к скрипту менялся.

```
wget -O pgpro-repo-add.sh https://raw.githubusercontent.com/klim1286/postgres-for-1C/main/pgpro-repo-add-1c-15.sh
```
Запускаем скрипт, обновляем репозиторий и устанавливаем postgrespro
```
sh pgpro-repo-add.sh && apt update && apt-get install postgrespro-1c-15
```
Меняем пароль:
```
sudo -i -u postgres /opt/pgpro/1c-15/bin/psql -U postgres -c "alter user postgres with password 'тут_вводим_пароль';" 
```
Проверяем запуск службы postgrespro-1c-{14,15,16}
```
systemctl status postgrespro-1c-15
```

## 3. Настройки на Master

Будем настраивать серверы с IP-адресами 192.168.0.30 (sourse или master) и 192.168.0.31 (replica или slave).

Переходим на сервер, с которого будем реплицировать данные (sourse) и выполняем следующие действия.

Создаем пользователя в PostgreSQL

Входим в систему под пользователем postgres:
```
su - postgres
```
Создаем нового пользователя для репликации:
```
createuser --replication -P repluser
```
* система запросит пароль — его нужно придумать и ввести дважды. В данном примере мы создаем пользователя repluser.

Выходим из оболочки пользователя postgres:
```
exit
```
Настраиваем postgresql

Смотрим расположение конфигурационного файла postgresql.conf командой:
```
su - postgres -c "psql -c 'SHOW config_file;'"
```
Вывод был таким:

/var/lib/pgpro/1c-15/data/postgresql.conf

Открываем конфигурационный файл postgresql.conf.
```
vi /var/lib/pgpro/1c-15/data/postgresql.conf
```
Редактируем следующие параметры:
```
listen_addresses = 'localhost, 192.168.0.30'
wal_level = replica
max_wal_senders = 2
max_replication_slots = 2
hot_standby = on
hot_standby_feedback = on
```

***192.168.0.30*** — IP-адрес сервера, на котором он будем слушать запросы Postgre;

***wal_level*** указывает, сколько информации записывается в WAL (журнал операций, который используется для репликации);

***max_wal_senders*** — количество планируемых слейвов;

***max_replication_slots*** — максимальное число слотов репликации;

***hot_standby*** — определяет, можно или нет подключаться к postgresql для выполнения запросов в процессе восстановления;

***hot_standby_feedback*** — определяет, будет или нет сервер slave сообщать мастеру о запросах, которые он выполняет.

Открываем конфигурационный файл pg_hba.conf — он находитсяч в том же каталоге, что и файл postgresql.conf:
```
vi /var/lib/pgpro/1c-15/data/pg_hba.conf
```
Добавляем следующие строки:
```
host replication repluser 127.0.0.1/32 md5
host replication repluser 192.168.0.30/32 md5
host replication repluser 192.168.0.31/32 md5
```
* данной настройкой мы разрешаем подключение к базе данных replication пользователю repluser с локального сервера (localhost и 192.168.0.30) и сервера 192.168.0.31.

Перезапускаем службу postgresql:
```
systemctl restart postgrespro-1c-15
```
## 4. Настройки на Slave
Смотрим путь до конфигурационного файла postgresql:
```
su - postgres -c "psql -c 'SHOW data_directory;'" 
```
Вывод был таким:
***/var/lib/pgpro/1c-15/data***

Также смотрим путь до конфигурационного файла postgresql.conf (нам это понадобиться ниже):
```
su - postgres -c "psql -c 'SHOW config_file;'"
```
Вывод был таким:
***/var/lib/pgpro/1c-15/data/postgresql.conf***

Останавливаем сервис postgresql:
```
systemctl stop postgrespro-1c-15
```
На всякий случай, создаем архив базы:
```
tar -czvf /tmp/data_pgsql.tar.gz /var/lib/pgpro/1c-15/data
```
* в данном примере мы сохраним все содержимое каталога /var/lib/pgpro/1c-15/data в виде архива /tmp/data_pgsql.tar.gz

Удаляем содержимое каталога с данными:
```
rm -rf /var/lib/pgpro/1c-15/data/*
```
И реплицируем данные с master сервера.
```
su - postgres -c "pg_basebackup --host=192.168.0.30 --username=repluser --pgdata=/var/lib/pgpro/1c-15/data --wal-method=stream --write-recovery-conf"
```
* где 192.168.0.30 — IP-адрес мастера; /var/lib/pgpro/1c-15/data/ — путь до каталога с данными.

После ввода команды система запросит пароль для созданной ранее учетной записи repluser — вводим его. Начнется процесс клонирования данных.

Открываем конфигурационный файл postgresql.conf на слейве:
```
vi /var/lib/pgpro/1c-15/data/postgresql.conf
```
И редактируем следующие параметры:
```
listen_addresses = 'localhost, 192.168.0.31'
```
* где 192.168.0.31 — IP-адрес нашего вторичного сервера.

Снова запускаем сервис postgresql:
```
systemctl start postgrespro-1c-15
```
## 5. Проверка репликации
Посмотреть статус работы репликации можно посмотреть следующими командами.

Входим в postgres
```
su - postgres -c "psql"
```
Выполняем запрос на мастере:
```
select * from pg_stat_replication;
```
Выполняем запрос на слейве:
```
select * from pg_stat_wal_receiver;
```

Список баз можно посмотреть командой:
```
su - postgres -c "psql"
```
```
\l
```
