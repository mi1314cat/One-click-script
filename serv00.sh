wget https://raw.githubusercontent.com/XyHK-HUC/Serv00-Reg/main/main.py
sudo apt update
sudo apt install python3-pip -y
python3 -m pip install pytz
pip install -r https://raw.githubusercontent.com/XyHK-HUC/Serv00-Reg/main/requirements.txt
python3 -m pip install --upgrade requests
python3 main.py
