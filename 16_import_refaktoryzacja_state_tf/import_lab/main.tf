# Przejmowane ręcznie utworzone VPC:
resource "aws_vpc" "reczne" {
  cidr_block = "10.160.0.0/16"
  
  tags = {
    Name = "import-vpc"
  }
}


# Przejmowana recznie utworzona podsiec:
# (Zostaly TYLKO cztery atrybuty - reszta z 20+ wygenerowanych to byly null-e,
#  wartosci domyslne, atrybuty wyliczane i te, ktore wywolaly nasze cztery bledy.)
resource "aws_subnet" "reczna" {
  vpc_id            = aws_vpc.reczne.id       # <- referencja zamiast sztywnego "vpc-0abc..."!
  cidr_block        = "10.160.1.0/24"
  availability_zone = "eu-north-1a"           # <- z pary AZ zostawiamy TE, bez "availability_zone_id"
 
  tags = {
    Name = "import-subnet"
  }
}
 
# Przejmowana recznie utworzona security group:
resource "aws_security_group" "reczna" {
  name        = "import-sg"
  description = "Reczna SG do cwiczenia importu"
  vpc_id      = aws_vpc.reczne.id             # <- referencja!
 
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instancja do cwiczen refaktoryzacyjnych - teraz jako modul:
module "serwer" {
  source = "./modules/serwer"
 
  ami_id            = data.aws_ami.ubuntu.id
  instance_type     = "t3.micro"
  subnet_id         = aws_subnet.reczna.id
  security_group_id = aws_security_group.reczna.id
 
  tags = {
    Name = "import-lab-web"
  }
}
 
# Przeprowadzka: to TEN SAM zasob, tylko pod nowym adresem - nie niszcz go!
moved {
  from = aws_instance.serwer_www
  to   = module.serwer.aws_instance.this
}

# Tymczasowe VPC do cwiczenia "zapominania" (VPC nic nie kosztuje):
resource "aws_vpc" "tymczasowe" {
  cidr_block = "10.170.0.0/16"
 
  tags = {
    Name = "import-lab-tymczasowe"
  }
}