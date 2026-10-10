#!/bin/bash
cd /usr/local/jenkins-service
java -jar agent.jar -url https://jenkins.adminakademia.lan/ -secret <sekret> -name linux2 -webSocket -workDir "/jenkins"
