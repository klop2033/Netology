###############Переменные#########################    Можно разбить по файлам Terraform сожрет
variable "cloud_id" {
    type=string
    default="b1gtm33iqcnv4kbjpll8" #Из личного кабинета YC
}
variable "folder_id" {
    type=string
    default="b1ggou49esjloni8jfof" #Из личного кабинета YC
}

variable "test" {                  # Технические характеристики виртуальных машин
    type=map(number)
    default={
    cores         = 2              # Количество ядер 
    memory        = 1              # объем оперативной памяти
    core_fraction = 5             # 5-20-100% выбрать нужный
  }
}
################Переменные сверху#################
### Авторизация в облаке ###
terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.129.0"
    }
  }

  required_version = ">=1.8.4"
}

provider "yandex" {
  # token                    = "do not use!!!"
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  service_account_key_file = file("./authorized_key.json") #ключ сгенерированный в облаке
}
#######
#создаем облачную сеть
resource "yandex_vpc_network" "netologydz" {
  name = "netologydz"
}
#создаем подсеть zone A netologydz_a создаеться в netologydz
resource "yandex_vpc_subnet" "netologydz_a" {
  name           = "netologydz-ru-central1-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.netologydz.id
  v4_cidr_blocks = ["10.11.12.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}
#######
#создаем подсеть zone B netologydz_b создаеться в netologydz
resource "yandex_vpc_subnet" "netologydz_b" {
  name           = "netologydz-ru-central1-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.netologydz.id
  v4_cidr_blocks = ["10.11.11.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}
###
#создаем NAT для выхода в интернет
resource "yandex_vpc_gateway" "nat_gateway" {
  name = "fops-gateway"
  shared_egress_gateway {}
}

#создаем сетевой маршрут для выхода в интернет через NAT
resource "yandex_vpc_route_table" "rt" {
  name       = "fops-route-table"
  network_id = yandex_vpc_network.netologydz.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

#создаем группы безопасности(firewall)

resource "yandex_vpc_security_group" "stena" {
  name       = "stena-sg"
  network_id = yandex_vpc_network.netologydz.id
  ingress {
    description    = "Allow 0.0.0.0/0"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }
  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }

}


resource "yandex_vpc_security_group" "LAN" {
  name       = "LAN-sg"
  network_id = yandex_vpc_network.netologydz.id
  ingress {
    description    = "Allow 10.0.0.0/8"
    protocol       = "ANY"
    v4_cidr_blocks = ["10.0.0.0/8"]
    from_port      = 0
    to_port        = 65535
  }
  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }

}

resource "yandex_vpc_security_group" "web_sg" {
  name       = "web-sg"
  network_id = yandex_vpc_network.netologydz.id


  ingress {
    description    = "Allow HTTPS"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description    = "Allow HTTP"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }


}


#считываем данные об образе ОС
data "yandex_compute_image" "ubuntu_2204_lts" {
  family = "ubuntu-2204-lts"
}
# Создаем и размещаем VPS в разных зонах

# создем VPS stena с белым ip, и во внутренней сетке web-server в зоне А, Базу данных в зоне Б.

### Создание VPS "Stena"
resource "yandex_compute_instance" "stena" {
  name        = "stena" #Имя ВМ в облачной консоли
  hostname    = "stena" #формирует FDQN имя хоста, без hostname будет сгенрировано случаное имя.
  platform_id = "standard-v3"
  zone        = "ru-central1-a" #зона ВМ должна совпадать с зоной subnet!!! ( VPS создаеться в netologydz_a )

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {                                      #Файл с SHH ключами.Ниже пример перекинь в другой файл
    user-data          = file("./cloud-init.yml")   # Создай "name.yml"
    serial-port-enable = 1
  }
  
  scheduling_policy { preemptible = true }  # Прерываемость VPS (Вырубиться через 24 часа)

  network_interface {
    subnet_id          = yandex_vpc_subnet.netologydz_a.id #зона ВМ должна совпадать с зоной subnet!!!
    nat                = true
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.stena.id]
  }
}
### Конец VPS "Stena" ###

### Начало VPS web-server ###
resource "yandex_compute_instance" "nginxweb" {
  name        = "nginxweb" #Имя ВМ в облачной консоли
  hostname    = "nginxweb" #формирует FDQN имя хоста, без hostname будет сгенрировано случаное имя.
  platform_id = "standard-v3"
  zone        = "ru-central1-a" #зона ВМ должна совпадать с зоной subnet!!! ( VPS создаеться netologydz_a )

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {                                      #Файл с SHH ключами.Ниже пример перекинь в другой файл
    user-data          = file("./cloud-init.yml")   # Создай "name.yml"
    serial-port-enable = 1
  }
  
# cloud-config
# users:
#   - name: user                        #                     #
#     groups: sudo                      #Создает пользователя #
#     shell: /bin/bash                  #и выдает права SUDO  #
#     sudo: ["ALL=(ALL) NOPASSWD:ALL"]  #                     #
#     ssh_authorized_keys:
#       - ##Сюда ключ ssh-ed25519 ##


  scheduling_policy { preemptible = true }  # Прерываемость VPS (Вырубиться через 24 часа)

  network_interface {
    subnet_id          = yandex_vpc_subnet.netologydz_a.id #зона ВМ должна совпадать с зоной subnet!!!
    nat                = false
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.web_sg.id]
  }
}
### Конец VPS web-server ###


### Начало VPS database ###
resource "yandex_compute_instance" "database" {
  name        = "database" #Имя ВМ в облачной консоли
  hostname    = "database" #формирует FDQN имя хоста, без hostname будет сгенрировано случаное имя.
  platform_id = "standard-v3"
  zone        = "ru-central1-b" #зона ВМ должна совпадать с зоной subnet!!!

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")   #Файл с SHH ключами.
    serial-port-enable = 1                          # Включение консоли в облаке
  }

  scheduling_policy { preemptible = true }  # Прерываемость VPS (Вырубиться через 24 часа)

  network_interface {
    subnet_id          = yandex_vpc_subnet.netologydz_b.id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.web_sg.id]
  }
}


###### Создание файла host.ini с пробросом ssh на database и nginxweb через 
resource "local_file" "inventory" {
  content  = <<-XYZ
  [stena]
  ${yandex_compute_instance.stena.network_interface.0.nat_ip_address}

  [webservers]
  ${yandex_compute_instance.database.network_interface.0.ip_address}
  ${yandex_compute_instance.nginxweb.network_interface.0.ip_address}
  [webservers:vars]
  ansible_ssh_common_args='-o ProxyCommand="ssh -p 22 -W %h:%p -q tet@${yandex_compute_instance.stena.network_interface.0.nat_ip_address}"'
  XYZ
  filename = "./hosts.ini"
}